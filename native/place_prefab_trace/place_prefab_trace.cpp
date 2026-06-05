#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

const wchar_t* kControlPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\place-prefab-trace-control.txt";
const wchar_t* kStatusPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\place-prefab-trace-status.txt";
const wchar_t* kEventPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\place-prefab-trace-events.tsv";
const wchar_t* kLogPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\place-prefab-trace.log";
const wchar_t* kSnapshotDir =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\place-prefab-trace-snapshots";

constexpr uintptr_t kDefaultSubmitCallsiteRva = 0x48A68BE;
constexpr uintptr_t kDefaultApplyEntryRva = 0x43DC230;
constexpr uintptr_t kDefaultMethodBlockRva = 0x6C79D50;

struct HashPattern {
    unsigned char bytes[32]{};
    char hex[65]{};
    char label[128]{};
};

struct PointerPattern {
    uintptr_t value = 0;
    char label[128]{};
};

struct Breakpoint {
    const char* name = "";
    uintptr_t rva = 0;
    uintptr_t address = 0;
    unsigned char original = 0;
    bool armed = false;
    std::atomic<uint64_t> hits{0};
};

Breakpoint g_breakpoints[2] = {
    {"submit_callsite", kDefaultSubmitCallsiteRva, 0, 0, false, 0},
    {"apply_entry", kDefaultApplyEntryRva, 0, 0, false, 0},
};

std::atomic<bool> g_enabled{true};
std::atomic<bool> g_installed{false};
std::atomic<uint64_t> g_breakpoint_exceptions{0};
std::atomic<uint64_t> g_singlestep_exceptions{0};
std::atomic<uint64_t> g_scan_hits{0};
std::atomic<uint64_t> g_snapshots{0};
uintptr_t g_module_base = 0;
uintptr_t g_method_block = 0;
SRWLOCK g_lock = SRWLOCK_INIT;
PVOID g_veh_handle = nullptr;
DWORD g_step_thread = 0;
int g_step_breakpoint = -1;
char g_last_event[512]{};
HashPattern g_hashes[64]{};
uint32_t g_hash_count = 0;
PointerPattern g_pointers[128]{};
uint32_t g_pointer_count = 0;

void ensure_parent(const wchar_t* path) {
    wchar_t buffer[MAX_PATH * 2]{};
    wcsncpy_s(buffer, path, _TRUNCATE);
    wchar_t* slash = wcsrchr(buffer, L'\\');
    if (!slash) {
        return;
    }
    *slash = L'\0';
    CreateDirectoryW(buffer, nullptr);
}

void append_text(const wchar_t* path, const char* text) {
    ensure_parent(path);
    FILE* file = nullptr;
    _wfopen_s(&file, path, L"ab");
    if (!file) {
        return;
    }
    std::fwrite(text, 1, std::strlen(text), file);
    std::fclose(file);
}

void append_log(const char* message) {
    char line[1024]{};
    SYSTEMTIME st{};
    GetLocalTime(&st);
    std::snprintf(
        line,
        sizeof(line),
        "%04u-%02u-%02u %02u:%02u:%02u.%03u %s\n",
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds,
        message ? message : "");
    append_text(kLogPath, line);
}

void append_event(const char* kind, const char* details) {
    char line[4096]{};
    SYSTEMTIME st{};
    GetLocalTime(&st);
    std::snprintf(
        line,
        sizeof(line),
        "%04u-%02u-%02uT%02u:%02u:%02u.%03u\t%s\t%s\n",
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds,
        kind ? kind : "",
        details ? details : "");
    append_text(kEventPath, line);
    strncpy_s(g_last_event, line, _TRUNCATE);
}

void ensure_directory(const wchar_t* path) {
    CreateDirectoryW(path, nullptr);
}

std::string read_text(const wchar_t* path) {
    FILE* file = nullptr;
    _wfopen_s(&file, path, L"rb");
    if (!file) {
        return {};
    }
    std::fseek(file, 0, SEEK_END);
    long size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    if (size <= 0 || size > 1024 * 1024) {
        std::fclose(file);
        return {};
    }
    std::string text;
    text.resize(static_cast<size_t>(size));
    std::fread(text.data(), 1, text.size(), file);
    std::fclose(file);
    return text;
}

uintptr_t parse_numeric_literal(const char* text) {
    if (!text) {
        return 0;
    }
    while (*text == ' ' || *text == '\t') {
        ++text;
    }
    int base = 10;
    if (text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        text += 2;
        base = 16;
    }
    char* end = nullptr;
    uintptr_t value = static_cast<uintptr_t>(_strtoui64(text, &end, base));
    return end == text ? 0 : value;
}

uintptr_t parse_value(const std::string& text, const char* key, uintptr_t fallback) {
    std::string prefix = std::string(key) + "=";
    size_t pos = text.find(prefix);
    if (pos == std::string::npos) {
        return fallback;
    }
    return parse_numeric_literal(text.c_str() + pos + prefix.size());
}

bool parse_bool_value(const std::string& text, const char* key, bool fallback) {
    std::string prefix = std::string(key) + "=";
    size_t pos = text.find(prefix);
    if (pos == std::string::npos) {
        return fallback;
    }
    pos += prefix.size();
    while (pos < text.size() && (text[pos] == ' ' || text[pos] == '\t')) {
        ++pos;
    }
    return text.compare(pos, 1, "1") == 0 ||
        text.compare(pos, 4, "true") == 0 ||
        text.compare(pos, 3, "yes") == 0 ||
        text.compare(pos, 2, "on") == 0;
}

int hex_nibble(char c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f') {
        return 10 + c - 'a';
    }
    if (c >= 'A' && c <= 'F') {
        return 10 + c - 'A';
    }
    return -1;
}

bool parse_hash_line(const std::string& value, HashPattern& out) {
    std::string hex;
    hex.reserve(64);
    size_t label_start = std::string::npos;
    for (size_t index = 0; index < value.size(); ++index) {
        char c = value[index];
        if (std::isxdigit(static_cast<unsigned char>(c)) && hex.size() < 64) {
            hex.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));
            continue;
        }
        if (hex.size() >= 64 && label_start == std::string::npos && (c == '|' || c == ',' || c == ' ')) {
            label_start = index + 1;
        }
    }
    if (hex.size() != 64) {
        return false;
    }
    for (size_t index = 0; index < 32; ++index) {
        int high = hex_nibble(hex[index * 2]);
        int low = hex_nibble(hex[index * 2 + 1]);
        if (high < 0 || low < 0) {
            return false;
        }
        out.bytes[index] = static_cast<unsigned char>((high << 4) | low);
    }
    strncpy_s(out.hex, hex.c_str(), _TRUNCATE);
    if (label_start != std::string::npos && label_start < value.size()) {
        strncpy_s(out.label, value.c_str() + label_start, _TRUNCATE);
    }
    return true;
}

bool parse_pointer_line(const std::string& value, PointerPattern& out) {
    out.value = parse_numeric_literal(value.c_str());
    if (out.value == 0) {
        return false;
    }
    size_t label_start = value.find('|');
    if (label_start == std::string::npos) {
        label_start = value.find(',');
    }
    if (label_start != std::string::npos && label_start + 1 < value.size()) {
        strncpy_s(out.label, value.c_str() + label_start + 1, _TRUNCATE);
    }
    return true;
}

void load_control() {
    std::string text = read_text(kControlPath);
    g_enabled.store(parse_bool_value(text, "enable", true));
    g_breakpoints[0].rva = parse_value(text, "submit_callsite_rva", kDefaultSubmitCallsiteRva);
    g_breakpoints[1].rva = parse_value(text, "apply_func_rva", parse_value(text, "apply_entry_rva", kDefaultApplyEntryRva));
    g_method_block = g_module_base + parse_value(text, "method_block_rva", kDefaultMethodBlockRva);

    uint32_t next_hash_count = 0;
    uint32_t next_pointer_count = 0;
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        if (end == std::string::npos) {
            end = text.size();
        }
        std::string line = text.substr(start, end - start);
        const char* hash_key = "hash=";
        const char* pointer_key = "ptr=";
        const char* pointer_key_long = "pointer=";
        if (line.rfind(hash_key, 0) == 0 && next_hash_count < ARRAYSIZE(g_hashes)) {
            HashPattern pattern{};
            if (parse_hash_line(line.substr(std::strlen(hash_key)), pattern)) {
                g_hashes[next_hash_count++] = pattern;
            }
        } else if (line.rfind(pointer_key, 0) == 0 && next_pointer_count < ARRAYSIZE(g_pointers)) {
            PointerPattern pattern{};
            if (parse_pointer_line(line.substr(std::strlen(pointer_key)), pattern)) {
                g_pointers[next_pointer_count++] = pattern;
            }
        } else if (line.rfind(pointer_key_long, 0) == 0 && next_pointer_count < ARRAYSIZE(g_pointers)) {
            PointerPattern pattern{};
            if (parse_pointer_line(line.substr(std::strlen(pointer_key_long)), pattern)) {
                g_pointers[next_pointer_count++] = pattern;
            }
        }
        start = end + 1;
    }
    g_hash_count = next_hash_count;
    g_pointer_count = next_pointer_count;
}

bool is_readable(uintptr_t address, size_t bytes) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || bytes == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return false;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return false;
    }
    uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
    uintptr_t region_end = region_start + mbi.RegionSize;
    return address >= region_start && address + bytes <= region_end;
}

bool read_process_bytes(uintptr_t address, void* out, size_t bytes) {
    if (!is_readable(address, bytes)) {
        return false;
    }
    SIZE_T read = 0;
    return ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(address), out, bytes, &read) &&
        read == bytes;
}

void write_snapshot_file(
    const char* bp_name,
    const char* label,
    uintptr_t address,
    const unsigned char* data,
    size_t length) {
    ensure_directory(kSnapshotDir);
    wchar_t path[MAX_PATH * 2]{};
    std::swprintf(
        path,
        ARRAYSIZE(path),
        L"%s\\%llu_%S_%S_0x%p.bin",
        kSnapshotDir,
        static_cast<unsigned long long>(g_snapshots.fetch_add(1) + 1),
        bp_name,
        label,
        reinterpret_cast<void*>(address));

    FILE* file = nullptr;
    _wfopen_s(&file, path, L"wb");
    if (!file) {
        return;
    }
    std::fwrite(data, 1, length, file);
    std::fclose(file);

    char details[1024]{};
    std::snprintf(
        details,
        sizeof(details),
        "bp=%s label=%s address=0x%p bytes=%zu path=%S",
        bp_name,
        label,
        reinterpret_cast<void*>(address),
        length,
        path);
    append_event("snapshot", details);
}

void snapshot_region(const char* bp_name, const char* label, uintptr_t address, size_t max_bytes) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return;
    }
    uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
    uintptr_t region_end = region_start + mbi.RegionSize;
    if (address < region_start || address >= region_end) {
        return;
    }
    size_t length = static_cast<size_t>(region_end - address);
    if (length > max_bytes) {
        length = max_bytes;
    }
    if (length == 0 || length > 0x20000) {
        return;
    }

    std::vector<unsigned char> data(length);
    SIZE_T read = 0;
    if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(address), data.data(), length, &read) ||
        read == 0) {
        return;
    }
    write_snapshot_file(bp_name, label, address, data.data(), static_cast<size_t>(read));
}

void log_qwords(const char* bp_name, const char* label, uintptr_t address, size_t bytes) {
    if (bytes > 0x100) {
        bytes = 0x100;
    }
    std::vector<unsigned char> data(bytes);
    SIZE_T read = 0;
    if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(address), data.data(), bytes, &read) ||
        read < sizeof(uintptr_t)) {
        return;
    }
    for (size_t off = 0; off + sizeof(uintptr_t) <= static_cast<size_t>(read); off += sizeof(uintptr_t)) {
        uintptr_t value = 0;
        std::memcpy(&value, data.data() + off, sizeof(value));
        if (value == 0) {
            continue;
        }
        char details[512]{};
        std::snprintf(
            details,
            sizeof(details),
            "bp=%s label=%s base=0x%p offset=0x%zX qword=0x%p",
            bp_name,
            label,
            reinterpret_cast<void*>(address),
            off,
            reinterpret_cast<void*>(value));
        append_event("qword", details);
    }
}

void scan_region(const char* bp_name, const char* label, uintptr_t address, size_t max_bytes, int depth);

void note_scan_hit(const char* bp_name, const char* label, uintptr_t address, size_t offset, const char* what) {
    char details[1024]{};
    std::snprintf(
        details,
        sizeof(details),
        "bp=%s label=%s address=0x%p offset=0x%zX hit=%s",
        bp_name,
        label,
        reinterpret_cast<void*>(address),
        offset,
        what);
    g_scan_hits.fetch_add(1);
    append_event("scan_hit", details);
}

void scan_buffer(
    const char* bp_name,
    const char* label,
    uintptr_t address,
    const unsigned char* data,
    size_t length,
    int depth) {
    if (g_method_block != 0) {
        for (size_t off = 0; off + sizeof(uintptr_t) <= length; off += sizeof(uintptr_t)) {
            uintptr_t value = 0;
            std::memcpy(&value, data + off, sizeof(value));
            if (value == g_method_block) {
                note_scan_hit(bp_name, label, address, off, "BrickAction_PlacePrefab_method_block");
            }
        }
    }

    for (uint32_t index = 0; index < g_pointer_count; ++index) {
        const PointerPattern& pattern = g_pointers[index];
        for (size_t off = 0; off + sizeof(uintptr_t) <= length; off += sizeof(uintptr_t)) {
            uintptr_t value = 0;
            std::memcpy(&value, data + off, sizeof(value));
            if (value == pattern.value) {
                char what[256]{};
                std::snprintf(what, sizeof(what), "ptr:0x%p:%s", reinterpret_cast<void*>(pattern.value), pattern.label);
                note_scan_hit(bp_name, label, address, off, what);
            }
        }
    }

    for (uint32_t index = 0; index < g_hash_count; ++index) {
        const HashPattern& pattern = g_hashes[index];
        for (size_t off = 0; off + sizeof(pattern.bytes) <= length; ++off) {
            if (std::memcmp(data + off, pattern.bytes, sizeof(pattern.bytes)) == 0) {
                char what[256]{};
                std::snprintf(what, sizeof(what), "hash:%s:%s", pattern.hex, pattern.label);
                note_scan_hit(bp_name, label, address, off, what);
            }
        }
    }

    if (depth <= 0) {
        return;
    }
    const size_t pointer_scan = length < 0x200 ? length : 0x200;
    for (size_t off = 0; off + sizeof(uintptr_t) <= pointer_scan; off += sizeof(uintptr_t)) {
        uintptr_t value = 0;
        std::memcpy(&value, data + off, sizeof(value));
        if (is_readable(value, 0x20)) {
            char child_label[96]{};
            std::snprintf(child_label, sizeof(child_label), "%s.qword+0x%zX", label, off);
            scan_region(bp_name, child_label, value, 0x2000, depth - 1);
        }
    }
}

void scan_region(const char* bp_name, const char* label, uintptr_t address, size_t max_bytes, int depth) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return;
    }
    uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
    uintptr_t region_end = region_start + mbi.RegionSize;
    if (address < region_start || address >= region_end) {
        return;
    }
    size_t length = static_cast<size_t>(region_end - address);
    if (length > max_bytes) {
        length = max_bytes;
    }
    if (length == 0 || length > 0x20000) {
        return;
    }

    std::vector<unsigned char> data(length);
    SIZE_T read = 0;
    if (!ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(address), data.data(), length, &read) ||
        read == 0) {
        return;
    }
    scan_buffer(bp_name, label, address, data.data(), static_cast<size_t>(read), depth);
}

void write_status(const char* reason) {
    ensure_parent(kStatusPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kStatusPath, L"wb");
    if (!file) {
        return;
    }
    std::fprintf(file, "feature=place-prefab-trace\n");
    std::fprintf(file, "reason=%s\n", reason ? reason : "");
    std::fprintf(file, "pid=%lu\n", GetCurrentProcessId());
    std::fprintf(file, "installed=%d\n", g_installed.load() ? 1 : 0);
    std::fprintf(file, "enabled=%d\n", g_enabled.load() ? 1 : 0);
    std::fprintf(file, "module_base=0x%p\n", reinterpret_cast<void*>(g_module_base));
    std::fprintf(file, "method_block=0x%p\n", reinterpret_cast<void*>(g_method_block));
    std::fprintf(file, "breakpoint_exceptions=%llu\n", static_cast<unsigned long long>(g_breakpoint_exceptions.load()));
    std::fprintf(file, "singlestep_exceptions=%llu\n", static_cast<unsigned long long>(g_singlestep_exceptions.load()));
    std::fprintf(file, "scan_hits=%llu\n", static_cast<unsigned long long>(g_scan_hits.load()));
    std::fprintf(file, "snapshots=%llu\n", static_cast<unsigned long long>(g_snapshots.load()));
    std::fprintf(file, "hash_count=%u\n", g_hash_count);
    std::fprintf(file, "pointer_count=%u\n", g_pointer_count);
    for (int index = 0; index < 2; ++index) {
        const Breakpoint& bp = g_breakpoints[index];
        std::fprintf(file, "%s_rva=0x%llX\n", bp.name, static_cast<unsigned long long>(bp.rva));
        std::fprintf(file, "%s_address=0x%p\n", bp.name, reinterpret_cast<void*>(bp.address));
        std::fprintf(file, "%s_armed=%d\n", bp.name, bp.armed ? 1 : 0);
        std::fprintf(file, "%s_original=0x%02X\n", bp.name, bp.original);
        std::fprintf(file, "%s_hits=%llu\n", bp.name, static_cast<unsigned long long>(bp.hits.load()));
    }
    std::fprintf(file, "last_event=%s\n", g_last_event);
    std::fclose(file);
}

bool write_byte(uintptr_t address, unsigned char value) {
    DWORD old_protect = 0;
    if (!VirtualProtect(reinterpret_cast<void*>(address), 1, PAGE_EXECUTE_READWRITE, &old_protect)) {
        return false;
    }
    *reinterpret_cast<volatile unsigned char*>(address) = value;
    DWORD ignored = 0;
    VirtualProtect(reinterpret_cast<void*>(address), 1, old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<void*>(address), 1);
    return true;
}

bool arm_breakpoint(Breakpoint& bp) {
    if (!g_enabled.load()) {
        return true;
    }
    if (bp.rva == 0) {
        bp.address = 0;
        bp.armed = false;
        return true;
    }
    if (bp.armed) {
        return true;
    }
    bp.address = g_module_base + bp.rva;
    unsigned char current = 0;
    if (!read_process_bytes(bp.address, &current, sizeof(current))) {
        return false;
    }
    if (current == 0xCC) {
        bp.armed = true;
        return true;
    }
    bp.original = current;
    if (!write_byte(bp.address, 0xCC)) {
        return false;
    }
    bp.armed = true;
    return true;
}

bool disarm_breakpoint(Breakpoint& bp) {
    if (!bp.armed) {
        return true;
    }
    if (!write_byte(bp.address, bp.original)) {
        return false;
    }
    bp.armed = false;
    return true;
}

int find_breakpoint(uintptr_t address) {
    for (int index = 0; index < 2; ++index) {
        if (g_breakpoints[index].armed && g_breakpoints[index].address == address) {
            return index;
        }
    }
    return -1;
}

void trace_context(const Breakpoint& bp, CONTEXT* context) {
    uintptr_t stack5 = 0;
    uintptr_t stack6 = 0;
    read_process_bytes(static_cast<uintptr_t>(context->Rsp) + 0x28, &stack5, sizeof(stack5));
    read_process_bytes(static_cast<uintptr_t>(context->Rsp) + 0x30, &stack6, sizeof(stack6));

    char details[2048]{};
    std::snprintf(
        details,
        sizeof(details),
        "bp=%s rip=0x%p rcx=0x%p rdx=0x%p r8=0x%p r9=0x%p rsp=0x%p stack5=0x%p stack6=0x%p",
        bp.name,
        reinterpret_cast<void*>(context->Rip),
        reinterpret_cast<void*>(context->Rcx),
        reinterpret_cast<void*>(context->Rdx),
        reinterpret_cast<void*>(context->R8),
        reinterpret_cast<void*>(context->R9),
        reinterpret_cast<void*>(context->Rsp),
        reinterpret_cast<void*>(stack5),
        reinterpret_cast<void*>(stack6));
    append_event("breakpoint", details);

    snapshot_region(bp.name, "rcx", static_cast<uintptr_t>(context->Rcx), 0x800);
    snapshot_region(bp.name, "rdx", static_cast<uintptr_t>(context->Rdx), 0x1000);
    snapshot_region(bp.name, "r8", static_cast<uintptr_t>(context->R8), 0x800);
    snapshot_region(bp.name, "r9", static_cast<uintptr_t>(context->R9), 0x800);
    snapshot_region(bp.name, "stack5", stack5, 0x800);
    snapshot_region(bp.name, "stack6", stack6, 0x400);

    log_qwords(bp.name, "rcx", static_cast<uintptr_t>(context->Rcx), 0x80);
    log_qwords(bp.name, "rdx", static_cast<uintptr_t>(context->Rdx), 0x100);
    log_qwords(bp.name, "r8", static_cast<uintptr_t>(context->R8), 0x80);
    log_qwords(bp.name, "r9", static_cast<uintptr_t>(context->R9), 0x80);

    uintptr_t action_payload = 0;
    if (read_process_bytes(static_cast<uintptr_t>(context->Rcx) + 0x18, &action_payload, sizeof(action_payload))) {
        snapshot_region(bp.name, "rcx_plus_18_ptr", action_payload, 0x4000);
        log_qwords(bp.name, "rcx_plus_18_ptr", action_payload, 0x100);
    }

    scan_region(bp.name, "rcx", static_cast<uintptr_t>(context->Rcx), 0x4000, 1);
    scan_region(bp.name, "rdx", static_cast<uintptr_t>(context->Rdx), 0x8000, 2);
    scan_region(bp.name, "r8", static_cast<uintptr_t>(context->R8), 0x2000, 1);
    scan_region(bp.name, "r9", static_cast<uintptr_t>(context->R9), 0x2000, 1);
    scan_region(bp.name, "stack5", stack5, 0x4000, 1);
    scan_region(bp.name, "stack6", stack6, 0x4000, 1);
}

LONG CALLBACK veh_handler(EXCEPTION_POINTERS* pointers) {
    if (!pointers || !pointers->ExceptionRecord || !pointers->ContextRecord) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    CONTEXT* context = pointers->ContextRecord;
    DWORD code = pointers->ExceptionRecord->ExceptionCode;
    if (code == EXCEPTION_BREAKPOINT) {
        uintptr_t address = static_cast<uintptr_t>(context->Rip) - 1;
        int bp_index = find_breakpoint(address);
        if (bp_index < 0) {
            address = reinterpret_cast<uintptr_t>(pointers->ExceptionRecord->ExceptionAddress);
            bp_index = find_breakpoint(address);
        }
        if (bp_index < 0) {
            return EXCEPTION_CONTINUE_SEARCH;
        }

        AcquireSRWLockExclusive(&g_lock);
        Breakpoint& bp = g_breakpoints[bp_index];
        bp.hits.fetch_add(1);
        g_breakpoint_exceptions.fetch_add(1);
        disarm_breakpoint(bp);
        context->Rip = bp.address;
        context->EFlags |= 0x100;
        g_step_thread = GetCurrentThreadId();
        g_step_breakpoint = bp_index;
        trace_context(bp, context);
        write_status("breakpoint-hit");
        ReleaseSRWLockExclusive(&g_lock);
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    if (code == EXCEPTION_SINGLE_STEP && GetCurrentThreadId() == g_step_thread && g_step_breakpoint >= 0) {
        AcquireSRWLockExclusive(&g_lock);
        g_singlestep_exceptions.fetch_add(1);
        arm_breakpoint(g_breakpoints[g_step_breakpoint]);
        context->EFlags &= ~0x100ULL;
        g_step_breakpoint = -1;
        g_step_thread = 0;
        write_status("single-step-rearmed");
        ReleaseSRWLockExclusive(&g_lock);
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    return EXCEPTION_CONTINUE_SEARCH;
}

void install_trace() {
    g_module_base = reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    load_control();

    g_veh_handle = AddVectoredExceptionHandler(1, veh_handler);
    if (!g_veh_handle) {
        append_log("AddVectoredExceptionHandler failed");
        write_status("veh-failed");
        return;
    }

    AcquireSRWLockExclusive(&g_lock);
    bool ok = true;
    ok = arm_breakpoint(g_breakpoints[0]) && ok;
    ok = arm_breakpoint(g_breakpoints[1]) && ok;
    g_installed.store(ok);
    ReleaseSRWLockExclusive(&g_lock);

    append_log(ok ? "place prefab trace installed" : "place prefab trace partially installed");
    append_event("installed", ok ? "ok=1" : "ok=0");
    write_status(ok ? "installed" : "partial-install");
}

DWORD WINAPI monitor_thread(void*) {
    install_trace();
    while (true) {
        Sleep(1000);
        write_status("heartbeat");
    }
}

}  // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        HANDLE thread = CreateThread(nullptr, 0, monitor_thread, nullptr, 0, nullptr);
        if (thread) {
            CloseHandle(thread);
        }
    }
    return TRUE;
}
