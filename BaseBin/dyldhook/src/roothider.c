#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <limits.h>
#include <mach/mach.h>
#include <sys/mman.h>

#include "machomerger_hook.h"
#include "dyld_jbinfo.h"
#include "dyld.h"

#define ROOTHIDE_LOADER_PREFIX "@loader_path/.jbroot"

typedef struct Loader Loader;
typedef struct LoadOptions LoadOptions;
typedef struct RuntimeState RuntimeState;

// ============================================================================
// DSC entry-point trampoline support
//
// On customer (non-development) shared caches, the cache builder applies
// "stub optimization" that converts GOT-mediated inter-dylib stubs into
// direct ADRP+ADD+BR sequences.  When a jbroot framework overrides a DSC
// framework, dyld's standard GOT patching cannot redirect these optimized
// stubs.  The result is that some call sites in non-overridden DSC client
// dylibs still branch directly into the DSC copy of the overridden
// framework, causing dual-initialization and PAC traps.
//
// Fix: after dyld's standard GOT patching, write short trampolines at the
// *entry point* of every exported function in the overridden DSC dylib.
// Any caller — whether through a patched GOT, an optimized stub, or a
// direct BL — will hit the trampoline and be redirected to the jbroot
// override.
//
// The trampoline is:
//   ADRP  X16, override_target@page
//   ADD   X16, X16, override_target@pageoff
//   BR    X16
// (12 bytes = 3 instructions, overwrites the first 3 insns of the DSC func)
// ============================================================================

// --- Minimal DSC structures (from dyld_cache_format.h / CachePatching.h) ---

struct dsc_header {
    char        magic[16];
    uint32_t    mappingOffset;
    uint32_t    mappingCount;
    uint32_t    imagesOffsetOld;
    uint32_t    imagesCountOld;
    uint64_t    dyldBaseAddress;
    uint64_t    codeSignatureOffset;
    uint64_t    codeSignatureSize;
    uint64_t    slideInfoOffsetUnused;
    uint64_t    slideInfoSizeUnused;
    uint64_t    localSymbolsOffset;
    uint64_t    localSymbolsSize;
    uint8_t     uuid[16];
    uint64_t    cacheType;
    uint32_t    branchPoolsOffset;
    uint32_t    branchPoolsCount;
    uint64_t    dyldInCacheMH;
    uint64_t    dyldInCacheEntry;
    uint64_t    imagesTextOffset;
    uint64_t    imagesTextCount;
    uint64_t    patchInfoAddr;       // unslid VM addr of patch info
    uint64_t    patchInfoSize;
    uint64_t    otherImageGroupAddrUnused;
    uint64_t    otherImageGroupSizeUnused;
    uint64_t    progClosuresAddr;
    uint64_t    progClosuresSize;
    uint64_t    progClosuresTrieAddr;
    uint64_t    progClosuresTrieSize;
    uint32_t    platform;
    uint32_t    formatBits;
    uint64_t    sharedRegionStart;   // unslid base address for the cache
    uint64_t    sharedRegionSize;
    uint64_t    maxSlide;
    // ... more fields follow but we don't need them for iteration
    // The imagesOffset / imagesCount are at fixed offsets further down:
    // +0x1C0 / +0x1C4 in the extended header
};

// Extended offsets we read manually (they are past the struct above)
#define DSC_IMAGES_OFFSET_FIELDOFF  0x1C0
#define DSC_IMAGES_COUNT_FIELDOFF   0x1C4

struct dsc_image_info {
    uint64_t    address;             // unslid mach_header vmaddr
    uint64_t    modTime;
    uint64_t    inode;
    uint32_t    pathFileOffset;
    uint32_t    pad;
};

struct dsc_patch_info_v2 {
    uint32_t    patchTableVersion;
    uint32_t    patchLocationVersion;
    uint64_t    patchTableArrayAddr;
    uint64_t    patchTableArrayCount;
    uint64_t    patchImageExportsArrayAddr;
    uint64_t    patchImageExportsArrayCount;
    // remaining fields are not needed for export iteration
};

struct dsc_image_patches_v2 {
    uint32_t    patchClientsStartIndex;
    uint32_t    patchClientsCount;
    uint32_t    patchExportsStartIndex;
    uint32_t    patchExportsCount;
};

struct dsc_image_export_v2 {
    uint32_t    dylibOffsetOfImpl;
    uint32_t    exportNameOffsetAndKind;  // low 28 bits = name offset, high 4 bits = patchKind
};

// DylibPatch mirrors dyld4::Loader::DylibPatch
struct DylibPatch {
    int64_t     overrideOffsetOfImpl;
};
#define DYLIBPATCH_END          ((int64_t)-1)
#define DYLIBPATCH_MISSING      ((int64_t)0)
#define DYLIBPATCH_OBJCCLASS    ((int64_t)1)
#define DYLIBPATCH_SINGLETON    ((int64_t)2)

// Saved during isOverridablePath hook — first field of ProcessConfig::DyldCache
static const void *gDyldCacheAddr = NULL;

// --- ARM64 trampoline encoding helpers ---

static void write_adrp_add_br_trampoline(void *dsc_func, void *override_func)
{
    uint64_t pc       = (uint64_t)dsc_func;
    uint64_t target   = (uint64_t)override_func;
    int64_t  adrpDelta = (int64_t)((target & ~0xFFFULL) - (pc & ~0xFFFULL));

    // ADRP can address ±4 GB
    if (adrpDelta > 0x100000000LL || adrpDelta < -0x100000000LL)
        return;

    uint32_t immhi   = (uint32_t)((adrpDelta >> 9) & 0x00FFFFE0);
    uint32_t immlo   = (uint32_t)((adrpDelta << 17) & 0x60000000);
    uint32_t off12   = (uint32_t)(target & 0xFFF);

    uint32_t insn[3];
    insn[0] = 0x90000010 | immlo | immhi;       // ADRP X16, target@page
    insn[1] = 0x91000210 | (off12 << 10);       // ADD  X16, X16, target@pageoff
    insn[2] = 0xD61F0200;                       // BR   X16

    // iOS uses 16 KB pages
    const uint64_t PAGE_MASK = ~0x3FFFULL;
    uintptr_t page_start = (uintptr_t)dsc_func & PAGE_MASK;
    uintptr_t page_end   = ((uintptr_t)dsc_func + 12 + 0x3FFF) & PAGE_MASK;
    size_t    region_len  = page_end - page_start;

    // Make writable (triggers per-process COW on the shared DSC page)
    mach_port_t self_port = task_self_trap();
    kern_return_t kr = vm_protect(self_port, (vm_address_t)page_start,
                                  (vm_size_t)region_len, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        return;

    // Write trampoline
    volatile uint32_t *dst = (volatile uint32_t *)dsc_func;
    dst[0] = insn[0];
    dst[1] = insn[1];
    dst[2] = insn[2];

    // Restore to r-x
    vm_protect(self_port, (vm_address_t)page_start,
               (vm_size_t)region_len, false,
               VM_PROT_READ | VM_PROT_EXECUTE);

    // Ensure instruction cache coherency (inline; no libcompiler_rt in this environment)
    __asm__ volatile (
        "dc cvau, %0\n"
        "dc cvau, %1\n"
        "dsb ish\n"
        "ic ivau, %0\n"
        "ic ivau, %1\n"
        "dsb ish\n"
        "isb\n"
        :: "r"((uintptr_t)dsc_func), "r"((uintptr_t)dsc_func + 8)
        : "memory"
    );
}

// ---- applyCachePatches hook ----
// Mangled: Loader::applyCachePatches(RuntimeState&, DyldCacheDataConstLazyScopedWriter&) const
// After the original patches global GOTs, we write entry-point trampolines
// in the overridden DSC dylib's TEXT so that optimized stubs are also caught.

// We call these dyld-internal functions by their mangled names:
//   Loader::overridesDylibInCache(const DylibPatch*&, uint16_t&) const
//   Loader::loadAddress(RuntimeState&) const
extern bool loader_overridesDylibInCache(const void *self, const struct DylibPatch **patchesOut, uint16_t *indexOut)
    __asm__("_MACHOMERGER_TRAMPOLINE__ZNK5dyld46Loader21overridesDylibInCacheERPKNS0_10DylibPatchERt");
extern const void *loader_loadAddress(const void *self, void *state)
    __asm__("_MACHOMERGER_TRAMPOLINE__ZNK5dyld46Loader11loadAddressERNS_12RuntimeStateE");

extern void ORIG(_ZNK5dyld46Loader17applyCachePatchesERNS_12RuntimeStateERNS_34DyldCacheDataConstLazyScopedWriterE)(const void *self, void *state, void *cacheDataConst);

void HOOK(_ZNK5dyld46Loader17applyCachePatchesERNS_12RuntimeStateERNS_34DyldCacheDataConstLazyScopedWriterE)(const void *self, void *state, void *cacheDataConst)
{
    // 1. Let dyld do standard GOT patching first
    ORIG(_ZNK5dyld46Loader17applyCachePatchesERNS_12RuntimeStateERNS_34DyldCacheDataConstLazyScopedWriterE)(self, state, cacheDataConst);

    // 2. Check if this loader overrides a cached dylib
    const struct DylibPatch *patches = NULL;
    uint16_t overriddenIndex = 0;
    if (!loader_overridesDylibInCache(self, &patches, &overriddenIndex))
        return;
    if (!patches)
        return;
    if (!gDyldCacheAddr)
        return;

    // 3. Get the override image's runtime base address
    const void *overrideBase = loader_loadAddress(self, state);
    if (!overrideBase)
        return;

    // 4. Navigate the DSC patch table to find the exports of the overridden dylib
    const struct dsc_header *hdr = (const struct dsc_header *)gDyldCacheAddr;
    int64_t slide = (int64_t)((intptr_t)gDyldCacheAddr - (intptr_t)hdr->sharedRegionStart);

    // Get the overridden DSC dylib's load address
    uint32_t imagesOffset = *(const uint32_t *)((const uint8_t *)hdr + DSC_IMAGES_OFFSET_FIELDOFF);
    const struct dsc_image_info *images = (const struct dsc_image_info *)((const uint8_t *)hdr + imagesOffset);
    uint64_t dscDylibBase = images[overriddenIndex].address + (uint64_t)slide;

    // Get patch table arrays
    if (hdr->patchInfoAddr == 0 || hdr->patchInfoSize == 0)
        return;
    const struct dsc_patch_info_v2 *patchInfo =
        (const struct dsc_patch_info_v2 *)((uintptr_t)hdr->patchInfoAddr + slide);
    if (patchInfo->patchTableVersion < 2)
        return;

    const struct dsc_image_patches_v2 *imagePatches =
        (const struct dsc_image_patches_v2 *)((uintptr_t)patchInfo->patchTableArrayAddr + slide);
    const struct dsc_image_export_v2 *imageExports =
        (const struct dsc_image_export_v2 *)((uintptr_t)patchInfo->patchImageExportsArrayAddr + slide);

    const struct dsc_image_patches_v2 *imgPatch = &imagePatches[overriddenIndex];
    const struct DylibPatch *patchEntry = patches;

    // 5. For each patchable export, write a trampoline at the DSC entry point
    for (uint32_t i = 0; i < imgPatch->patchExportsCount; i++, patchEntry++) {
        int64_t overrideOff = patchEntry->overrideOffsetOfImpl;

        // Skip sentinel / special values
        if (overrideOff == DYLIBPATCH_END)
            break;
        if (overrideOff == DYLIBPATCH_MISSING ||
            overrideOff == DYLIBPATCH_OBJCCLASS ||
            overrideOff == DYLIBPATCH_SINGLETON)
            continue;

        const struct dsc_image_export_v2 *exp =
            &imageExports[imgPatch->patchExportsStartIndex + i];

        uintptr_t dscFuncAddr      = (uintptr_t)(dscDylibBase + exp->dylibOffsetOfImpl);
        uintptr_t overrideFuncAddr = (uintptr_t)overrideBase + (uintptr_t)((intptr_t)overrideOff);

        write_adrp_add_br_trampoline((void *)dscFuncAddr, (void *)overrideFuncAddr);
    }
}

// class static method, no "this" parameter
extern bool ORIG(_ZN5dyld46Loader18expandAtLoaderPathERNS_12RuntimeStateEPKcRKNS0_11LoadOptionsEPKS0_bPc)(RuntimeState* state, const char* loadPath, const LoadOptions* options, const Loader* ldr, bool fromLCRPATH, char fixedPath[]);
bool HOOK(_ZN5dyld46Loader18expandAtLoaderPathERNS_12RuntimeStateEPKcRKNS0_11LoadOptionsEPKS0_bPc)(RuntimeState* state, const char* loadPath, const LoadOptions* options, const Loader* ldr, bool fromLCRPATH, char fixedPath[])
{
    bool ret = ORIG(_ZN5dyld46Loader18expandAtLoaderPathERNS_12RuntimeStateEPKcRKNS0_11LoadOptionsEPKS0_bPc)(state, loadPath, options, ldr, fromLCRPATH, fixedPath);
    if (ret) {
        if (strncmp(loadPath, ROOTHIDE_LOADER_PREFIX, sizeof(ROOTHIDE_LOADER_PREFIX)-1) == 0)
        {
            if ((loadPath[sizeof(ROOTHIDE_LOADER_PREFIX)-1] != '/') && (loadPath[sizeof(ROOTHIDE_LOADER_PREFIX)-1] != '\0')) {
                return ret;
            }
            
            char *jbroot = jbinfo_get_jbroot();
            if (jbroot) {
                strlcpy(fixedPath, jbroot, PATH_MAX);
                strlcat(fixedPath, &loadPath[sizeof(ROOTHIDE_LOADER_PREFIX)-1], PATH_MAX);
            }
        }
    }
    return ret;
}

extern bool ORIG(_ZNK5dyld413ProcessConfig9DyldCache17isOverridablePathEPKc)(const void *dyldCache, const char *dylibPath);
bool HOOK(_ZNK5dyld413ProcessConfig9DyldCache17isOverridablePathEPKc)(const void *dyldCache, const char *dylibPath)
{
    // `dyldCache` is `this` for ProcessConfig::DyldCache.
    // Its first field is `const DyldSharedCache* addr` — the cache base pointer.
    if (!gDyldCacheAddr && dyldCache) {
        gDyldCacheAddr = *(const void *const *)dyldCache;
    }
    (void)dylibPath;
    return true;
}

// isAlwaysOverridablePath is a static method used in PrebuiltLoader::invalidateInIsolation
// to decide whether to check for on-disk roots on customer caches.
// Without this hook, DSC PrebuiltLoaders bypass getLoader() entirely and directly load
// DSC dependencies (via PrebuiltLoader::dependent()), ignoring DYLD_FRAMEWORK_PATH overrides.
// Returning true here forces root-checking for all DSC PrebuiltLoaders, causing them to be
// invalidated when a DYLD_FRAMEWORK_PATH override exists on disk. The invalidation cascades
// to all transitive dependents via invalidateShallow(), forcing JIT loaders which properly
// resolve dependencies through getLoader() and detect already-loaded override images.
extern bool ORIG(_ZN5dyld413ProcessConfig9DyldCache23isAlwaysOverridablePathEPKc)(const char *dylibPath);
bool HOOK(_ZN5dyld413ProcessConfig9DyldCache23isAlwaysOverridablePathEPKc)(const char *dylibPath)
{
    (void)dylibPath;
    return true;
}

// ============================================================================
// matchesPath hook — prevent double-loading of jbroot overrides
//
// Problem: DYLD_FRAMEWORK_PATH is set to /var/containers/.../Library/Frameworks
// but dyld canonicalizes loaded paths via fcntl(F_GETPATH) to /private/var/...
// When a late dlopen() generates the DYLD_FRAMEWORK_PATH variant, matchesPath()
// compares "/var/..." against the stored "/private/var/..." → mismatch → dyld
// creates a second Loader for the same file → ObjC sees duplicate classes → crash.
//
// Fix: normalize /var/ ↔ /private/var/ before the string comparison.
// ============================================================================
extern bool ORIG(_ZNK5dyld416JustInTimeLoader11matchesPathEPKc)(const void *self, const char *path);
bool HOOK(_ZNK5dyld416JustInTimeLoader11matchesPathEPKc)(const void *self, const char *path)
{
    if (ORIG(_ZNK5dyld416JustInTimeLoader11matchesPathEPKc)(self, path))
        return true;

    // /var/... → try /private/var/...
    if (path[0] == '/' && path[1] == 'v' && path[2] == 'a' && path[3] == 'r' && path[4] == '/') {
        char buf[PATH_MAX];
        strlcpy(buf, "/private", PATH_MAX);
        strlcat(buf, path, PATH_MAX);
        if (ORIG(_ZNK5dyld416JustInTimeLoader11matchesPathEPKc)(self, buf))
            return true;
    }

    // /private/var/... → try /var/...
    if (strncmp(path, "/private/var/", 13) == 0) {
        if (ORIG(_ZNK5dyld416JustInTimeLoader11matchesPathEPKc)(self, path + 8))
            return true;
    }

    return false;
}

bool SPINLOCK_FIX_DISABLED = false;

void dyldhook_init_roothide(uintptr_t kernelParams)
{
#if IOS==15 && __arm64e__
	uintptr_t argc = *(uintptr_t *)(kernelParams + sizeof(void *));
	char **envp = (char **)(kernelParams + sizeof(void *) + sizeof(argc) + (sizeof(const char *) * argc) + sizeof(void *));
	
    // When we disable dyld patch globally, we may still inject dyld patch for some processes such as WebContent, but we don't need spinlock fix
    // but dyldpatch for WebContent is only for ios16???
	if (_simple_getenv(envp, "SPINLOCK_FIX_DISABLED")) {
		SPINLOCK_FIX_DISABLED = true;
	}
#endif
}
