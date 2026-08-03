#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <atomic>
#include <cctype>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

const wchar_t* kControlPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\placement-asset-guard-control.txt";
const wchar_t* kStatusPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\placement-asset-guard-status.txt";
const wchar_t* kLogPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\placement-asset-guard.log";
const wchar_t* kEventPath =
    L"C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\placement-asset-guard-events.tsv";

using NativeFunc = void(__fastcall*)(void* context, void* stack, void* result);
using ActionApplyFunc = void(__fastcall*)(
    void* action,
    void* transaction,
    void* context,
    void* target,
    void* errors,
    void* permissions);
using PlacePrefabApplyFunc = void(__fastcall*)(
    void* action,
    void* transaction,
    void* context,
    void* target,
    void* errors,
    void* permissions);
using ResolveBrickRefFunc = uintptr_t(__fastcall*)(void* brick_ref);
using ResolveBrickPrimaryFunc = uintptr_t(__fastcall*)(uintptr_t record);
using ResolveBrickVariantFunc = uintptr_t(__fastcall*)(uintptr_t record, void* variant_ref);
using BrickClassFunc = uintptr_t(__fastcall*)();

constexpr uint32_t kCapabilityLegacy = 1u << 0;
constexpr uint32_t kCapabilityMechanic = 1u << 1;
constexpr uint32_t kCapabilityAdmin = 1u << 2;
constexpr uint32_t kCapabilityAll = 0xFFFFFFFFu;

struct DeniedAsset {
    uintptr_t address = 0;
    char name[128]{};
    uint32_t required_capabilities = kCapabilityLegacy;
};

struct DeniedPrefabHash {
    unsigned char hash[32]{};
    char hash_hex[65]{};
    char asset_name[128]{};
    uint32_t required_capabilities = kCapabilityLegacy;
};

struct AllowedContextCapabilities {
    uintptr_t address = 0;
    uint32_t capabilities = 0;
};

std::atomic<bool> g_enabled{false};
std::atomic<bool> g_block{true};
std::atomic<bool> g_trace{true};
std::atomic<bool> g_installed{false};
std::atomic<bool> g_prefab_installed{false};
std::atomic<bool> g_action_prefab_installed{false};
std::atomic<bool> g_action_brick_installed{false};
std::atomic<uintptr_t> g_function{0};
std::atomic<uintptr_t> g_prefab_function{0};
std::atomic<uintptr_t> g_place_prefab_method_block{0};
std::atomic<uintptr_t> g_place_brick_method_block{0};
std::atomic<uintptr_t> g_place_brick_resolve_ref{0};
std::atomic<uintptr_t> g_place_brick_primary_class{0};
std::atomic<uintptr_t> g_place_brick_variant_class{0};
std::atomic<uintptr_t> g_place_brick_asset_class{0};
std::atomic<uintptr_t> g_place_brick_resolve_primary{0};
std::atomic<uintptr_t> g_place_brick_resolve_variant{0};
std::atomic<uint32_t> g_func_offset{0xD8};
std::atomic<uint32_t> g_prefab_func_offset{0xD8};
std::atomic<uint32_t> g_locals_offset{0x28};
std::atomic<uint32_t> g_asset_offset{0x80};
std::atomic<uint32_t> g_prefab_hash_offset{0x0};
std::atomic<uint32_t> g_place_prefab_apply_slot_offset{0x18};
std::atomic<uint32_t> g_place_prefab_payload_offset{0x18};
std::atomic<uint32_t> g_place_prefab_payload_hash_offset{0x28};
std::atomic<uint32_t> g_place_brick_apply_slot_offset{0x18};
std::atomic<uint32_t> g_place_brick_ref_offset{0x1C};
std::atomic<uint32_t> g_place_brick_variant_offset{0x24};
std::atomic<uint32_t> g_place_brick_asset_record_offset{0x20};
std::atomic<uint64_t> g_hits{0};
std::atomic<uint64_t> g_blocks{0};
std::atomic<uint64_t> g_allows{0};
std::atomic<uint64_t> g_prefab_hits{0};
std::atomic<uint64_t> g_prefab_blocks{0};
std::atomic<uint64_t> g_prefab_allows{0};
std::atomic<uint64_t> g_action_prefab_hits{0};
std::atomic<uint64_t> g_action_prefab_blocks{0};
std::atomic<uint64_t> g_action_prefab_allows{0};
std::atomic<uint64_t> g_action_prefab_param_read_failures{0};
std::atomic<uint64_t> g_action_brick_hits{0};
std::atomic<uint64_t> g_action_brick_blocks{0};
std::atomic<uint64_t> g_action_brick_allows{0};
std::atomic<uint64_t> g_action_brick_param_read_failures{0};
std::atomic<uint64_t> g_passthrough{0};
std::atomic<uint64_t> g_param_read_failures{0};
std::atomic<uint64_t> g_prefab_param_read_failures{0};
std::atomic<uint64_t> g_prefab_frame_scan_hits{0};
std::atomic<uint64_t> g_allowed_context_overflow{0};

void** g_func_slot = nullptr;
NativeFunc g_original = nullptr;
void** g_prefab_func_slot = nullptr;
NativeFunc g_prefab_original = nullptr;
void** g_place_prefab_apply_slot = nullptr;
PlacePrefabApplyFunc g_place_prefab_apply_original = nullptr;
void** g_place_brick_apply_slot = nullptr;
ActionApplyFunc g_place_brick_apply_original = nullptr;
SRWLOCK g_policy_lock = SRWLOCK_INIT;
DeniedAsset g_denied_assets[256]{};
uint32_t g_denied_asset_count = 0;
DeniedPrefabHash g_denied_prefab_hashes[256]{};
uint32_t g_denied_prefab_hash_count = 0;
AllowedContextCapabilities g_allowed_contexts[256]{};
uint32_t g_allowed_context_count = 0;

void __fastcall NativeFuncDetour(void* context, void* stack, void* result);
void __fastcall PrefabFuncDetour(void* context, void* stack, void* result);
void __fastcall PlacePrefabApplyDetour(
    void* action,
    void* transaction,
    void* context,
    void* target,
    void* errors,
    void* permissions);
void __fastcall PlaceBrickApplyDetour(
    void* action,
    void* transaction,
    void* context,
    void* target,
    void* errors,
    void* permissions);

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

void append_log(const char* fmt, ...) {
    ensure_parent(kLogPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kLogPath, L"ab");
    if (!file) {
        return;
    }

    SYSTEMTIME st{};
    GetLocalTime(&st);
    std::fprintf(
        file,
        "%04u-%02u-%02u %02u:%02u:%02u.%03u ",
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds);

    va_list args;
    va_start(args, fmt);
    std::vfprintf(file, fmt, args);
    va_end(args);
    std::fprintf(file, "\n");
    std::fclose(file);
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

std::string trim_ascii(const std::string& value) {
    size_t first = 0;
    while (first < value.size() && std::isspace(static_cast<unsigned char>(value[first]))) {
        ++first;
    }
    size_t last = value.size();
    while (last > first && std::isspace(static_cast<unsigned char>(value[last - 1]))) {
        --last;
    }
    return value.substr(first, last - first);
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
        base = 16;
        text += 2;
    }
    char* end = nullptr;
    uintptr_t value = static_cast<uintptr_t>(_strtoui64(text, &end, base));
    return end == text ? 0 : value;
}

bool find_control_value(const std::string& text, const char* key, std::string* out) {
    if (!key || !out) {
        return false;
    }

    size_t start = 0;
    while (start <= text.size()) {
        const size_t end = text.find_first_of("\r\n", start);
        const std::string line = text.substr(
            start,
            end == std::string::npos ? std::string::npos : end - start);
        const size_t equals = line.find('=');
        if (equals != std::string::npos && trim_ascii(line.substr(0, equals)) == key) {
            *out = trim_ascii(line.substr(equals + 1));
            return true;
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }

    return false;
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

bool parse_prefab_hash(const std::string& value, unsigned char* out, char* hex_out) {
    if (!out) {
        return false;
    }
    std::string cleaned;
    cleaned.reserve(64);
    for (char c : value) {
        if (std::isxdigit(static_cast<unsigned char>(c))) {
            cleaned.push_back(static_cast<char>(std::toupper(static_cast<unsigned char>(c))));
        }
    }
    if (cleaned.size() != 64) {
        return false;
    }
    for (size_t index = 0; index < 32; ++index) {
        const int high = hex_nibble(cleaned[index * 2]);
        const int low = hex_nibble(cleaned[index * 2 + 1]);
        if (high < 0 || low < 0) {
            return false;
        }
        out[index] = static_cast<unsigned char>((high << 4) | low);
    }
    if (hex_out) {
        strncpy_s(hex_out, 65, cleaned.c_str(), _TRUNCATE);
    }
    return true;
}

std::vector<std::string> split_policy_fields(const std::string& value) {
    std::vector<std::string> fields;
    size_t start = 0;
    while (start <= value.size()) {
        const size_t end = value.find('|', start);
        fields.push_back(trim_ascii(value.substr(
            start,
            end == std::string::npos ? std::string::npos : end - start)));
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    return fields;
}

uint32_t parse_capabilities(const std::string& value, uint32_t fallback) {
    uint32_t capabilities = 0;
    std::string token;
    const auto flush_token = [&]() {
        const std::string normalized = trim_ascii(token);
        token.clear();
        if (normalized.empty()) {
            return;
        }
        std::string lowered;
        lowered.reserve(normalized.size());
        for (char c : normalized) {
            lowered.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
        }
        if (lowered == "all" || lowered == "bypass" || lowered == "*") {
            capabilities = kCapabilityAll;
        } else if (lowered == "legacy" || lowered == "default") {
            capabilities |= kCapabilityLegacy;
        } else if (lowered == "mechanic" || lowered == "ismechanic" || lowered == "is mechanic" ||
                   lowered == "spacemechanic" || lowered == "isspacemechanic" || lowered == "is space mechanic") {
            capabilities |= kCapabilityMechanic;
        } else if (lowered == "admin" || lowered == "administrator") {
            capabilities |= kCapabilityAdmin;
        }
    };

    for (char c : value) {
        if (c == ',' || c == '+' || c == ';') {
            flush_token();
        } else {
            token.push_back(c);
        }
    }
    flush_token();
    return capabilities == 0 ? fallback : capabilities;
}

void format_capabilities(uint32_t capabilities, char* out, size_t out_size) {
    if (!out || out_size == 0) {
        return;
    }
    out[0] = '\0';
    if (capabilities == kCapabilityAll) {
        strncpy_s(out, out_size, "all", _TRUNCATE);
        return;
    }
    std::string text;
    const auto append = [&](const char* name) {
        if (!text.empty()) {
            text.push_back(',');
        }
        text.append(name);
    };
    if ((capabilities & kCapabilityLegacy) != 0) {
        append("legacy");
    }
    if ((capabilities & kCapabilityMechanic) != 0) {
        append("mechanic");
    }
    if ((capabilities & kCapabilityAdmin) != 0) {
        append("admin");
    }
    if (text.empty()) {
        text = "none";
    }
    strncpy_s(out, out_size, text.c_str(), _TRUNCATE);
}

uintptr_t parse_hex_value(const std::string& text, const char* key, uintptr_t fallback = 0) {
    std::string value;
    if (!find_control_value(text, key, &value)) {
        return fallback;
    }
    return parse_numeric_literal(value.c_str());
}

bool parse_bool_value(const std::string& text, const char* key, bool fallback) {
    std::string value;
    if (!find_control_value(text, key, &value)) {
        return fallback;
    }
    size_t pos = 0;
    while (pos < value.size() && (value[pos] == ' ' || value[pos] == '\t')) {
        ++pos;
    }
    return value.compare(pos, 1, "1") == 0 ||
        value.compare(pos, 4, "true") == 0 ||
        value.compare(pos, 3, "yes") == 0 ||
        value.compare(pos, 2, "on") == 0;
}

bool is_accessible_memory(uintptr_t address, size_t bytes) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || bytes == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return false;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return false;
    }
    const uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
    const uintptr_t region_end = region_start + mbi.RegionSize;
    return address >= region_start && address + bytes <= region_end;
}

bool is_executable_memory(uintptr_t address) {
    MEMORY_BASIC_INFORMATION mbi{};
    if (address == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0) {
        return false;
    }
    if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS)) {
        return false;
    }
    const DWORD execute_flags =
        PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
    return (mbi.Protect & execute_flags) != 0;
}

void parse_policy_lists(const std::string& text) {
    std::vector<DeniedAsset> denied_assets;
    std::vector<DeniedPrefabHash> denied_prefab_hashes;
    AllowedContextCapabilities allowed_contexts[256]{};
    uint32_t allowed_context_count = 0;
    uint64_t overflow = 0;

    size_t start = 0;
    while (start <= text.size()) {
        size_t end = text.find_first_of("\r\n", start);
        std::string line = text.substr(start, end == std::string::npos ? std::string::npos : end - start);
        size_t equals = line.find('=');
        if (equals != std::string::npos) {
            std::string key = trim_ascii(line.substr(0, equals));
            std::string value = trim_ascii(line.substr(equals + 1));
            if (key == "denied_asset" || key == "deny_asset" || key == "denied_entity" || key == "deny_entity") {
                const auto fields = split_policy_fields(value);
                const uintptr_t parsed = fields.empty() ? 0 : parse_numeric_literal(fields[0].c_str());
                if (parsed != 0) {
                    const uint32_t required = fields.size() >= 3
                        ? parse_capabilities(fields[2], kCapabilityLegacy)
                        : kCapabilityLegacy;
                    bool duplicate = false;
                    for (auto& existing : denied_assets) {
                        if (existing.address == parsed) {
                            existing.required_capabilities |= required;
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        if (denied_assets.size() < 256) {
                            DeniedAsset rule{};
                            rule.address = parsed;
                            rule.required_capabilities = required;
                            if (fields.size() >= 2 && !fields[1].empty()) {
                                strncpy_s(rule.name, fields[1].c_str(), _TRUNCATE);
                            }
                            denied_assets.push_back(rule);
                        } else {
                            ++overflow;
                        }
                    }
                }
            } else if (key == "denied_prefab_hash" || key == "deny_prefab_hash" || key == "denied_hash" || key == "deny_hash") {
                const auto fields = split_policy_fields(value);
                const std::string hash_text = fields.empty() ? "" : fields[0];
                DeniedPrefabHash rule{};
                if (parse_prefab_hash(hash_text, rule.hash, rule.hash_hex)) {
                    if (fields.size() >= 2 && !fields[1].empty()) {
                        strncpy_s(rule.asset_name, fields[1].c_str(), _TRUNCATE);
                    }
                    rule.required_capabilities = fields.size() >= 3
                        ? parse_capabilities(fields[2], kCapabilityLegacy)
                        : kCapabilityLegacy;
                    bool duplicate = false;
                    for (auto& existing : denied_prefab_hashes) {
                        if (std::memcmp(existing.hash, rule.hash, sizeof(rule.hash)) == 0) {
                            existing.required_capabilities |= rule.required_capabilities;
                            if (existing.asset_name[0] == '\0' && rule.asset_name[0] != '\0') {
                                strncpy_s(existing.asset_name, rule.asset_name, _TRUNCATE);
                            }
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        if (denied_prefab_hashes.size() < 256) {
                            denied_prefab_hashes.push_back(rule);
                        } else {
                            ++overflow;
                        }
                    }
                }
            } else if (key == "allowed_context" || key == "allow_context" ||
                       key == "allowed_context_capability" || key == "allow_context_capability") {
                const auto fields = split_policy_fields(value);
                const uintptr_t parsed = fields.empty() ? 0 : parse_numeric_literal(fields[0].c_str());
                if (parsed != 0) {
                    const uint32_t capabilities = (key == "allowed_context" || key == "allow_context")
                        ? kCapabilityAll
                        : (fields.size() >= 2 ? parse_capabilities(fields[1], 0) : 0);
                    bool duplicate = false;
                    for (uint32_t index = 0; index < allowed_context_count; ++index) {
                        if (allowed_contexts[index].address == parsed) {
                            allowed_contexts[index].capabilities |= capabilities;
                            duplicate = true;
                            break;
                        }
                    }
                    if (!duplicate) {
                        if (allowed_context_count < static_cast<uint32_t>(sizeof(allowed_contexts) / sizeof(allowed_contexts[0]))) {
                            allowed_contexts[allowed_context_count].address = parsed;
                            allowed_contexts[allowed_context_count].capabilities = capabilities;
                            ++allowed_context_count;
                        } else {
                            ++overflow;
                        }
                    }
                }
            }
        }

        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }

    AcquireSRWLockExclusive(&g_policy_lock);
    std::memset(g_denied_assets, 0, sizeof(g_denied_assets));
    if (!denied_assets.empty()) {
        std::memcpy(g_denied_assets, denied_assets.data(), denied_assets.size() * sizeof(DeniedAsset));
    }
    g_denied_asset_count = static_cast<uint32_t>(denied_assets.size());
    std::memset(g_denied_prefab_hashes, 0, sizeof(g_denied_prefab_hashes));
    if (!denied_prefab_hashes.empty()) {
        std::memcpy(
            g_denied_prefab_hashes,
            denied_prefab_hashes.data(),
            denied_prefab_hashes.size() * sizeof(DeniedPrefabHash));
    }
    g_denied_prefab_hash_count = static_cast<uint32_t>(denied_prefab_hashes.size());
    std::memset(g_allowed_contexts, 0, sizeof(g_allowed_contexts));
    std::memcpy(
        g_allowed_contexts,
        allowed_contexts,
        allowed_context_count * sizeof(AllowedContextCapabilities));
    g_allowed_context_count = allowed_context_count;
    ReleaseSRWLockExclusive(&g_policy_lock);

    if (overflow > 0) {
        g_allowed_context_overflow.fetch_add(overflow);
    }
}

bool load_control() {
    static std::string last_control_text;
    const std::string text = read_text(kControlPath);
    if (text.empty()) {
        return false;
    }

    const bool changed = text != last_control_text;
    if (!changed) {
        return false;
    }
    last_control_text = text;

    g_enabled.store(parse_bool_value(text, "enable", g_enabled.load()));
    g_block.store(parse_bool_value(text, "block", g_block.load()));
    g_trace.store(parse_bool_value(text, "trace", g_trace.load()));
    g_function.store(parse_hex_value(text, "function", g_function.load()));
    g_prefab_function.store(parse_hex_value(text, "prefab_function", g_prefab_function.load()));
    g_place_prefab_method_block.store(parse_hex_value(text, "place_prefab_method_block", g_place_prefab_method_block.load()));
    g_place_brick_method_block.store(parse_hex_value(text, "place_brick_method_block", g_place_brick_method_block.load()));
    g_place_brick_resolve_ref.store(parse_hex_value(text, "place_brick_resolve_ref", g_place_brick_resolve_ref.load()));
    g_place_brick_primary_class.store(parse_hex_value(text, "place_brick_primary_class", g_place_brick_primary_class.load()));
    g_place_brick_variant_class.store(parse_hex_value(text, "place_brick_variant_class", g_place_brick_variant_class.load()));
    g_place_brick_asset_class.store(parse_hex_value(text, "place_brick_asset_class", g_place_brick_asset_class.load()));
    g_place_brick_resolve_primary.store(parse_hex_value(text, "place_brick_resolve_primary", g_place_brick_resolve_primary.load()));
    g_place_brick_resolve_variant.store(parse_hex_value(text, "place_brick_resolve_variant", g_place_brick_resolve_variant.load()));
    g_func_offset.store(static_cast<uint32_t>(parse_hex_value(text, "func_offset", g_func_offset.load())));
    g_prefab_func_offset.store(static_cast<uint32_t>(parse_hex_value(text, "prefab_func_offset", g_prefab_func_offset.load())));
    g_locals_offset.store(static_cast<uint32_t>(parse_hex_value(text, "locals_offset", g_locals_offset.load())));
    g_asset_offset.store(static_cast<uint32_t>(parse_hex_value(text, "asset_offset", g_asset_offset.load())));
    g_prefab_hash_offset.store(static_cast<uint32_t>(parse_hex_value(text, "prefab_hash_offset", g_prefab_hash_offset.load())));
    g_place_prefab_apply_slot_offset.store(static_cast<uint32_t>(parse_hex_value(
        text,
        "place_prefab_apply_slot_offset",
        g_place_prefab_apply_slot_offset.load())));
    g_place_prefab_payload_offset.store(static_cast<uint32_t>(parse_hex_value(
        text,
        "place_prefab_payload_offset",
        g_place_prefab_payload_offset.load())));
    g_place_prefab_payload_hash_offset.store(static_cast<uint32_t>(parse_hex_value(
        text,
        "place_prefab_payload_hash_offset",
        g_place_prefab_payload_hash_offset.load())));
    g_place_brick_apply_slot_offset.store(static_cast<uint32_t>(parse_hex_value(
        text,
        "place_brick_apply_slot_offset",
        g_place_brick_apply_slot_offset.load())));
    g_place_brick_ref_offset.store(static_cast<uint32_t>(parse_hex_value(
        text,
        "place_brick_ref_offset",
        g_place_brick_ref_offset.load())));
    g_place_brick_variant_offset.store(static_cast<uint32_t>(parse_hex_value(
        text,
        "place_brick_variant_offset",
        g_place_brick_variant_offset.load())));
    g_place_brick_asset_record_offset.store(static_cast<uint32_t>(parse_hex_value(
        text,
        "place_brick_asset_record_offset",
        g_place_brick_asset_record_offset.load())));
    parse_policy_lists(text);
    return true;
}

bool context_has_capabilities(void* context, uint32_t required_capabilities, uint32_t* out_capabilities = nullptr) {
    const uintptr_t context_address = reinterpret_cast<uintptr_t>(context);
    if (context_address == 0) {
        return false;
    }

    bool allowed = false;
    uint32_t available = 0;
    AcquireSRWLockShared(&g_policy_lock);
    for (uint32_t index = 0; index < g_allowed_context_count; ++index) {
        if (g_allowed_contexts[index].address == context_address) {
            available = g_allowed_contexts[index].capabilities;
            allowed = (available & required_capabilities) == required_capabilities;
            break;
        }
    }
    ReleaseSRWLockShared(&g_policy_lock);
    if (out_capabilities) {
        *out_capabilities = available;
    }
    return allowed;
}

bool find_denied_asset(uintptr_t asset, DeniedAsset* out) {
    if (asset == 0) {
        return false;
    }
    bool found = false;
    AcquireSRWLockShared(&g_policy_lock);
    for (uint32_t index = 0; index < g_denied_asset_count; ++index) {
        if (g_denied_assets[index].address == asset) {
            if (out) {
                *out = g_denied_assets[index];
            }
            found = true;
            break;
        }
    }
    ReleaseSRWLockShared(&g_policy_lock);
    return found;
}

bool find_denied_prefab_hash(const unsigned char* hash, DeniedPrefabHash* out) {
    if (!hash) {
        return false;
    }
    bool found = false;
    AcquireSRWLockShared(&g_policy_lock);
    for (uint32_t index = 0; index < g_denied_prefab_hash_count; ++index) {
        if (std::memcmp(g_denied_prefab_hashes[index].hash, hash, 32) == 0) {
            if (out) {
                *out = g_denied_prefab_hashes[index];
            }
            found = true;
            break;
        }
    }
    ReleaseSRWLockShared(&g_policy_lock);
    return found;
}

void append_policy_event(
    const char* event_name,
    uint64_t event_id,
    void* context,
    uintptr_t locals,
    uintptr_t asset,
    const char* asset_name,
    const char* reason,
    uint32_t required_capabilities,
    uint32_t context_capabilities) {
    ensure_parent(kEventPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kEventPath, L"ab");
    if (!file) {
        return;
    }

    SYSTEMTIME st{};
    GetSystemTime(&st);
    const char* id_key = std::strcmp(event_name ? event_name : "", "block") == 0 ? "block_id" : "allow_id";
    char required_text[64]{};
    char context_text[64]{};
    format_capabilities(required_capabilities, required_text, sizeof(required_text));
    format_capabilities(context_capabilities, context_text, sizeof(context_text));
    std::fprintf(
        file,
        "event=%s\t%s=%llu\tpolicy_id=%llu\tutc=%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\tcontext=0x%p\tlocals=0x%p\tasset=0x%p\tasset_name=%s\trequired_capabilities=%s\tcontext_capabilities=%s\treason=%s\n",
        event_name ? event_name : "",
        id_key,
        static_cast<unsigned long long>(event_id),
        static_cast<unsigned long long>(event_id),
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds,
        context,
        reinterpret_cast<void*>(locals),
        reinterpret_cast<void*>(asset),
        asset_name ? asset_name : "",
        required_text,
        context_text,
        reason ? reason : "");
    std::fclose(file);
}

void append_prefab_policy_event(
    const char* event_name,
    uint64_t event_id,
    void* context,
    uintptr_t locals,
    const char* prefab_hash,
    const char* asset_name,
    const char* reason,
    uint32_t required_capabilities,
    uint32_t context_capabilities) {
    ensure_parent(kEventPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kEventPath, L"ab");
    if (!file) {
        return;
    }

    SYSTEMTIME st{};
    GetSystemTime(&st);
    const char* id_key = std::strcmp(event_name ? event_name : "", "block") == 0 ? "block_id" : "allow_id";
    char required_text[64]{};
    char context_text[64]{};
    format_capabilities(required_capabilities, required_text, sizeof(required_text));
    format_capabilities(context_capabilities, context_text, sizeof(context_text));
    std::fprintf(
        file,
        "event=%s\tkind=prefab\t%s=%llu\tpolicy_id=%llu\tutc=%04u-%02u-%02uT%02u:%02u:%02u.%03uZ\tcontext=0x%p\tlocals=0x%p\tprefab_hash=%s\tasset_name=%s\trequired_capabilities=%s\tcontext_capabilities=%s\treason=%s\n",
        event_name ? event_name : "",
        id_key,
        static_cast<unsigned long long>(event_id),
        static_cast<unsigned long long>(event_id),
        st.wYear,
        st.wMonth,
        st.wDay,
        st.wHour,
        st.wMinute,
        st.wSecond,
        st.wMilliseconds,
        context,
        reinterpret_cast<void*>(locals),
        prefab_hash ? prefab_hash : "",
        asset_name ? asset_name : "",
        required_text,
        context_text,
        reason ? reason : "");
    std::fclose(file);
}

void write_status(const char* reason) {
    ensure_parent(kStatusPath);
    FILE* file = nullptr;
    _wfopen_s(&file, kStatusPath, L"wb");
    if (!file) {
        return;
    }
    std::fprintf(file, "reason=%s\n", reason ? reason : "");
    std::fprintf(file, "pid=%lu\n", GetCurrentProcessId());
    std::fprintf(file, "installed=%d\n", g_installed.load() ? 1 : 0);
    std::fprintf(file, "prefab_installed=%d\n", g_prefab_installed.load() ? 1 : 0);
    std::fprintf(file, "action_prefab_installed=%d\n", g_action_prefab_installed.load() ? 1 : 0);
    std::fprintf(file, "action_brick_installed=%d\n", g_action_brick_installed.load() ? 1 : 0);
    std::fprintf(file, "enabled=%d\n", g_enabled.load() ? 1 : 0);
    std::fprintf(file, "block=%d\n", g_block.load() ? 1 : 0);
    std::fprintf(file, "trace=%d\n", g_trace.load() ? 1 : 0);
    std::fprintf(file, "function=0x%p\n", reinterpret_cast<void*>(g_function.load()));
    std::fprintf(file, "prefab_function=0x%p\n", reinterpret_cast<void*>(g_prefab_function.load()));
    std::fprintf(file, "place_prefab_method_block=0x%p\n", reinterpret_cast<void*>(g_place_prefab_method_block.load()));
    std::fprintf(file, "place_brick_method_block=0x%p\n", reinterpret_cast<void*>(g_place_brick_method_block.load()));
    std::fprintf(file, "place_brick_resolve_ref=0x%p\n", reinterpret_cast<void*>(g_place_brick_resolve_ref.load()));
    std::fprintf(file, "place_brick_primary_class=0x%p\n", reinterpret_cast<void*>(g_place_brick_primary_class.load()));
    std::fprintf(file, "place_brick_variant_class=0x%p\n", reinterpret_cast<void*>(g_place_brick_variant_class.load()));
    std::fprintf(file, "place_brick_asset_class=0x%p\n", reinterpret_cast<void*>(g_place_brick_asset_class.load()));
    std::fprintf(file, "place_brick_resolve_primary=0x%p\n", reinterpret_cast<void*>(g_place_brick_resolve_primary.load()));
    std::fprintf(file, "place_brick_resolve_variant=0x%p\n", reinterpret_cast<void*>(g_place_brick_resolve_variant.load()));
    std::fprintf(file, "func_offset=0x%X\n", g_func_offset.load());
    std::fprintf(file, "prefab_func_offset=0x%X\n", g_prefab_func_offset.load());
    std::fprintf(file, "locals_offset=0x%X\n", g_locals_offset.load());
    std::fprintf(file, "asset_offset=0x%X\n", g_asset_offset.load());
    std::fprintf(file, "prefab_hash_offset=0x%X\n", g_prefab_hash_offset.load());
    std::fprintf(file, "place_prefab_apply_slot_offset=0x%X\n", g_place_prefab_apply_slot_offset.load());
    std::fprintf(file, "place_prefab_payload_offset=0x%X\n", g_place_prefab_payload_offset.load());
    std::fprintf(file, "place_prefab_payload_hash_offset=0x%X\n", g_place_prefab_payload_hash_offset.load());
    std::fprintf(file, "place_brick_apply_slot_offset=0x%X\n", g_place_brick_apply_slot_offset.load());
    std::fprintf(file, "place_brick_ref_offset=0x%X\n", g_place_brick_ref_offset.load());
    std::fprintf(file, "place_brick_variant_offset=0x%X\n", g_place_brick_variant_offset.load());
    std::fprintf(file, "place_brick_asset_record_offset=0x%X\n", g_place_brick_asset_record_offset.load());
    std::fprintf(file, "func_slot=0x%p\n", reinterpret_cast<void*>(g_func_slot));
    std::fprintf(file, "original=0x%p\n", reinterpret_cast<void*>(g_original));
    std::fprintf(file, "detour=0x%p\n", reinterpret_cast<void*>(&NativeFuncDetour));
    std::fprintf(file, "prefab_func_slot=0x%p\n", reinterpret_cast<void*>(g_prefab_func_slot));
    std::fprintf(file, "prefab_original=0x%p\n", reinterpret_cast<void*>(g_prefab_original));
    std::fprintf(file, "prefab_detour=0x%p\n", reinterpret_cast<void*>(&PrefabFuncDetour));
    std::fprintf(file, "place_prefab_apply_slot=0x%p\n", reinterpret_cast<void*>(g_place_prefab_apply_slot));
    std::fprintf(file, "place_prefab_apply_original=0x%p\n", reinterpret_cast<void*>(g_place_prefab_apply_original));
    std::fprintf(file, "place_prefab_apply_detour=0x%p\n", reinterpret_cast<void*>(&PlacePrefabApplyDetour));
    std::fprintf(file, "place_brick_apply_slot=0x%p\n", reinterpret_cast<void*>(g_place_brick_apply_slot));
    std::fprintf(file, "place_brick_apply_original=0x%p\n", reinterpret_cast<void*>(g_place_brick_apply_original));
    std::fprintf(file, "place_brick_apply_detour=0x%p\n", reinterpret_cast<void*>(&PlaceBrickApplyDetour));
    std::fprintf(file, "event_path=C:\\Users\\tycox\\OneDrive\\Documents\\GitHub\\bmf\\artifacts\\local\\placement-asset-guard-events.tsv\n");
    std::fprintf(file, "hits=%llu\n", static_cast<unsigned long long>(g_hits.load()));
    std::fprintf(file, "blocks=%llu\n", static_cast<unsigned long long>(g_blocks.load()));
    std::fprintf(file, "allows=%llu\n", static_cast<unsigned long long>(g_allows.load()));
    std::fprintf(file, "prefab_hits=%llu\n", static_cast<unsigned long long>(g_prefab_hits.load()));
    std::fprintf(file, "prefab_blocks=%llu\n", static_cast<unsigned long long>(g_prefab_blocks.load()));
    std::fprintf(file, "prefab_allows=%llu\n", static_cast<unsigned long long>(g_prefab_allows.load()));
    std::fprintf(file, "action_prefab_hits=%llu\n", static_cast<unsigned long long>(g_action_prefab_hits.load()));
    std::fprintf(file, "action_prefab_blocks=%llu\n", static_cast<unsigned long long>(g_action_prefab_blocks.load()));
    std::fprintf(file, "action_prefab_allows=%llu\n", static_cast<unsigned long long>(g_action_prefab_allows.load()));
    std::fprintf(file, "action_brick_hits=%llu\n", static_cast<unsigned long long>(g_action_brick_hits.load()));
    std::fprintf(file, "action_brick_blocks=%llu\n", static_cast<unsigned long long>(g_action_brick_blocks.load()));
    std::fprintf(file, "action_brick_allows=%llu\n", static_cast<unsigned long long>(g_action_brick_allows.load()));
    std::fprintf(file, "passthrough=%llu\n", static_cast<unsigned long long>(g_passthrough.load()));
    std::fprintf(file, "param_read_failures=%llu\n", static_cast<unsigned long long>(g_param_read_failures.load()));
    std::fprintf(file, "prefab_param_read_failures=%llu\n", static_cast<unsigned long long>(g_prefab_param_read_failures.load()));
    std::fprintf(file, "prefab_frame_scan_hits=%llu\n", static_cast<unsigned long long>(g_prefab_frame_scan_hits.load()));
    std::fprintf(
        file,
        "action_prefab_param_read_failures=%llu\n",
        static_cast<unsigned long long>(g_action_prefab_param_read_failures.load()));
    std::fprintf(
        file,
        "action_brick_param_read_failures=%llu\n",
        static_cast<unsigned long long>(g_action_brick_param_read_failures.load()));
    AcquireSRWLockShared(&g_policy_lock);
    std::fprintf(file, "denied_asset_count=%u\n", g_denied_asset_count);
    for (uint32_t index = 0; index < g_denied_asset_count; ++index) {
        char required_text[64]{};
        format_capabilities(
            g_denied_assets[index].required_capabilities,
            required_text,
            sizeof(required_text));
        std::fprintf(
            file,
            "denied_asset_%u=0x%p|%s|%s\n",
            index + 1,
            reinterpret_cast<void*>(g_denied_assets[index].address),
            g_denied_assets[index].name,
            required_text);
    }
    std::fprintf(file, "denied_prefab_hash_count=%u\n", g_denied_prefab_hash_count);
    for (uint32_t index = 0; index < g_denied_prefab_hash_count; ++index) {
        char required_text[64]{};
        format_capabilities(
            g_denied_prefab_hashes[index].required_capabilities,
            required_text,
            sizeof(required_text));
        std::fprintf(
            file,
            "denied_prefab_hash_%u=%s|%s|%s\n",
            index + 1,
            g_denied_prefab_hashes[index].hash_hex,
            g_denied_prefab_hashes[index].asset_name,
            required_text);
    }
    std::fprintf(file, "allowed_context_count=%u\n", g_allowed_context_count);
    for (uint32_t index = 0; index < g_allowed_context_count; ++index) {
        char capability_text[64]{};
        format_capabilities(
            g_allowed_contexts[index].capabilities,
            capability_text,
            sizeof(capability_text));
        std::fprintf(
            file,
            "allowed_context_%u=0x%p|%s\n",
            index + 1,
            reinterpret_cast<void*>(g_allowed_contexts[index].address),
            capability_text);
    }
    ReleaseSRWLockShared(&g_policy_lock);
    std::fprintf(file, "allowed_context_overflow=%llu\n", static_cast<unsigned long long>(g_allowed_context_overflow.load()));
    std::fclose(file);
}

bool read_frame_locals(void* stack, uintptr_t* out_locals) {
    if (!stack || !out_locals) {
        return false;
    }
    uintptr_t locals = 0;
    __try {
        std::memcpy(&locals, static_cast<unsigned char*>(stack) + g_locals_offset.load(), sizeof(uintptr_t));
        if (locals == 0) {
            return false;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    *out_locals = locals;
    return true;
}

bool read_placement_asset(void* stack, uintptr_t* out_locals, uintptr_t* out_asset) {
    if (!out_locals || !out_asset) {
        return false;
    }
    uintptr_t locals = 0;
    uintptr_t asset = 0;
    if (!read_frame_locals(stack, &locals)) {
        return false;
    }
    __try {
        std::memcpy(&asset, reinterpret_cast<void*>(locals + g_asset_offset.load()), sizeof(uintptr_t));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    *out_locals = locals;
    *out_asset = asset;
    return true;
}

bool read_prefab_hash(void* stack, uintptr_t* out_locals, unsigned char* out_hash) {
    if (!out_locals || !out_hash) {
        return false;
    }
    uintptr_t locals = 0;
    if (!read_frame_locals(stack, &locals)) {
        return false;
    }
    __try {
        std::memcpy(out_hash, reinterpret_cast<void*>(locals + g_prefab_hash_offset.load()), 32);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    *out_locals = locals;
    return true;
}

bool read_bytes(uintptr_t address, void* out, size_t bytes) {
    if (!address || !out || !is_accessible_memory(address, bytes)) {
        return false;
    }
    __try {
        std::memcpy(out, reinterpret_cast<void*>(address), bytes);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }
    return true;
}

bool find_denied_prefab_hash_in_range(
    uintptr_t base,
    size_t bytes,
    DeniedPrefabHash* out_denied,
    uintptr_t* out_address,
    uint32_t* out_offset) {
    if (!base || bytes < 32 || !is_accessible_memory(base, bytes)) {
        return false;
    }

    bool found = false;
    AcquireSRWLockShared(&g_policy_lock);
    __try {
        const unsigned char* data = reinterpret_cast<const unsigned char*>(base);
        for (size_t offset = 0; offset + 32 <= bytes && !found; ++offset) {
            for (uint32_t index = 0; index < g_denied_prefab_hash_count; ++index) {
                if (std::memcmp(data + offset, g_denied_prefab_hashes[index].hash, 32) == 0) {
                    if (out_denied) {
                        *out_denied = g_denied_prefab_hashes[index];
                    }
                    if (out_address) {
                        *out_address = base + offset;
                    }
                    if (out_offset) {
                        *out_offset = static_cast<uint32_t>(offset);
                    }
                    found = true;
                    break;
                }
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        found = false;
    }
    ReleaseSRWLockShared(&g_policy_lock);
    return found;
}

bool find_denied_prefab_hash_in_frame(
    void* stack,
    DeniedPrefabHash* out_denied,
    uintptr_t* out_hash_address,
    uint32_t* out_frame_pointer_offset,
    uint32_t* out_hash_offset) {
    if (!stack) {
        return false;
    }

    // FFrame has changed layout between supported Brickadia builds. Search only
    // the small buffers referenced by plausible pointer fields; never scan the
    // process or arbitrary object graphs on the placement hot path.
    static constexpr uint32_t kFramePointerOffsets[] = {
        0x10, 0x18, 0x20, 0x28, 0x30, 0x38, 0x40, 0x48, 0x50, 0x58,
    };
    static constexpr size_t kCandidateBytes = 0x180;
    const uintptr_t frame = reinterpret_cast<uintptr_t>(stack);

    for (uint32_t frame_offset : kFramePointerOffsets) {
        uintptr_t candidate = 0;
        if (!read_bytes(frame + frame_offset, &candidate, sizeof(candidate)) || !candidate) {
            continue;
        }

        uintptr_t hash_address = 0;
        uint32_t hash_offset = 0;
        if (!find_denied_prefab_hash_in_range(
                candidate,
                kCandidateBytes,
                out_denied,
                &hash_address,
                &hash_offset)) {
            continue;
        }

        if (out_hash_address) {
            *out_hash_address = hash_address;
        }
        if (out_frame_pointer_offset) {
            *out_frame_pointer_offset = frame_offset;
        }
        if (out_hash_offset) {
            *out_hash_offset = hash_offset;
        }
        return true;
    }

    return false;
}

void format_prefab_hash(const unsigned char* hash, char* out, size_t out_size) {
    static const char* kHex = "0123456789ABCDEF";
    if (!hash || !out || out_size < 65) {
        if (out && out_size > 0) {
            out[0] = '\0';
        }
        return;
    }
    for (size_t index = 0; index < 32; ++index) {
        out[index * 2] = kHex[(hash[index] >> 4) & 0xF];
        out[index * 2 + 1] = kHex[hash[index] & 0xF];
    }
    out[64] = '\0';
}

bool read_place_prefab_action_hash(void* action, uintptr_t* out_payload, unsigned char* out_hash) {
    if (!action || !out_payload || !out_hash) {
        return false;
    }

    uintptr_t payload = 0;
    __try {
        std::memcpy(
            &payload,
            static_cast<unsigned char*>(action) + g_place_prefab_payload_offset.load(),
            sizeof(payload));
        if (payload == 0) {
            return false;
        }
        std::memcpy(
            out_hash,
            reinterpret_cast<void*>(payload + g_place_prefab_payload_hash_offset.load()),
            32);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    *out_payload = payload;
    return true;
}

bool read_ptr(uintptr_t address, uintptr_t* out) {
    if (!address || !out) {
        return false;
    }

    __try {
        std::memcpy(out, reinterpret_cast<void*>(address), sizeof(uintptr_t));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    return true;
}

bool read_i32(uintptr_t address, int* out) {
    if (!address || !out) {
        return false;
    }

    __try {
        std::memcpy(out, reinterpret_cast<void*>(address), sizeof(int));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    return true;
}

bool brick_object_is_a(uintptr_t object, uintptr_t class_object) {
    if (!object || !class_object) {
        return false;
    }

    uintptr_t object_class = 0;
    uintptr_t ancestry = 0;
    int object_depth = 0;
    int class_depth = 0;
    uintptr_t ancestry_entry = 0;

    if (!read_ptr(object + 0x10, &object_class) ||
        !read_i32(object_class + 0x38, &object_depth) ||
        !read_i32(class_object + 0x38, &class_depth) ||
        object_depth < class_depth ||
        !read_ptr(object_class + 0x30, &ancestry) ||
        !read_ptr(ancestry + static_cast<uintptr_t>(class_depth) * sizeof(uintptr_t), &ancestry_entry)) {
        return false;
    }

    return ancestry_entry == class_object + 0x30;
}

bool resolve_place_brick_action_asset(void* action, uintptr_t* out_record, uintptr_t* out_asset) {
    if (!action || !out_record || !out_asset) {
        return false;
    }

    const uintptr_t resolve_ref_address = g_place_brick_resolve_ref.load();
    const uintptr_t primary_class_address = g_place_brick_primary_class.load();
    const uintptr_t variant_class_address = g_place_brick_variant_class.load();
    const uintptr_t asset_class_address = g_place_brick_asset_class.load();
    const uintptr_t resolve_primary_address = g_place_brick_resolve_primary.load();
    const uintptr_t resolve_variant_address = g_place_brick_resolve_variant.load();
    if (!resolve_ref_address ||
        !primary_class_address ||
        !variant_class_address ||
        !asset_class_address ||
        !resolve_primary_address ||
        !resolve_variant_address) {
        return false;
    }

    const auto resolve_ref = reinterpret_cast<ResolveBrickRefFunc>(resolve_ref_address);
    const auto primary_class_fn = reinterpret_cast<BrickClassFunc>(primary_class_address);
    const auto variant_class_fn = reinterpret_cast<BrickClassFunc>(variant_class_address);
    const auto asset_class_fn = reinterpret_cast<BrickClassFunc>(asset_class_address);
    const auto resolve_primary = reinterpret_cast<ResolveBrickPrimaryFunc>(resolve_primary_address);
    const auto resolve_variant = reinterpret_cast<ResolveBrickVariantFunc>(resolve_variant_address);

    uintptr_t record = 0;
    uintptr_t asset = 0;
    __try {
        unsigned char* action_bytes = static_cast<unsigned char*>(action);
        void* brick_ref = action_bytes + g_place_brick_ref_offset.load();
        record = resolve_ref(brick_ref);
        if (!record) {
            return false;
        }

        const uintptr_t primary_class = primary_class_fn();
        const uintptr_t variant_class = variant_class_fn();
        if (brick_object_is_a(record, primary_class)) {
            record = resolve_primary(record);
        } else if (brick_object_is_a(record, variant_class)) {
            record = resolve_variant(record, action_bytes + g_place_brick_variant_offset.load());
        } else {
            return false;
        }

        if (!record) {
            return false;
        }

        if (!read_ptr(record + g_place_brick_asset_record_offset.load(), &asset) || !asset) {
            return false;
        }

        const uintptr_t asset_class = asset_class_fn();
        if (!brick_object_is_a(asset, asset_class)) {
            return false;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        return false;
    }

    *out_record = record;
    *out_asset = asset;
    return true;
}

void __fastcall NativeFuncDetour(void* context, void* stack, void* result) {
    const uint64_t hits = g_hits.fetch_add(1) + 1;
    uintptr_t locals = 0;
    uintptr_t asset = 0;
    const bool params_ok = read_placement_asset(stack, &locals, &asset);
    if (!params_ok) {
        g_param_read_failures.fetch_add(1);
    }

    DeniedAsset denied{};
    const bool denied_match = params_ok && find_denied_asset(asset, &denied);

    if (g_trace.load() && (hits <= 40 || denied_match || !params_ok)) {
        append_log(
            "hit context=0x%p stack=0x%p result=0x%p locals=0x%p asset=0x%p denied_match=%d asset_name=%s enabled=%d block=%d hits=%llu",
            context,
            stack,
            result,
            reinterpret_cast<void*>(locals),
            reinterpret_cast<void*>(asset),
            denied_match ? 1 : 0,
            denied.name,
            g_enabled.load() ? 1 : 0,
            g_block.load() ? 1 : 0,
            static_cast<unsigned long long>(hits));
    }

    if (g_enabled.load() && g_block.load() && denied_match) {
        uint32_t context_capabilities = 0;
        if (context_has_capabilities(context, denied.required_capabilities, &context_capabilities)) {
            const uint64_t allows = g_allows.fetch_add(1) + 1;
            append_policy_event(
                "allow",
                allows,
                context,
                locals,
                asset,
                denied.name,
                "ContextCapabilitiesSatisfied",
                denied.required_capabilities,
                context_capabilities);
            write_status("allowed");
            g_passthrough.fetch_add(1);
            if (g_original) {
                g_original(context, stack, result);
            }
            return;
        }

        const uint64_t blocks = g_blocks.fetch_add(1) + 1;
        append_policy_event(
            "block",
            blocks,
            context,
            locals,
            asset,
            denied.name,
            "PlacementAssetDenied",
            denied.required_capabilities,
            context_capabilities);
        append_log(
            "blocked ServerPlaceSimpleEntityVolume context=0x%p locals=0x%p asset=0x%p asset_name=%s blocks=%llu",
            context,
            reinterpret_cast<void*>(locals),
            reinterpret_cast<void*>(asset),
            denied.name,
            static_cast<unsigned long long>(blocks));
        write_status("blocked");
        return;
    }

    g_passthrough.fetch_add(1);
    if (g_original) {
        g_original(context, stack, result);
    }
}

void __fastcall PrefabFuncDetour(void* context, void* stack, void* result) {
    const uint64_t hits = g_prefab_hits.fetch_add(1) + 1;
    uintptr_t locals = 0;
    unsigned char hash[32]{};
    char raw_hash_hex[65]{};
    const bool params_ok = read_prefab_hash(stack, &locals, hash);
    if (!params_ok) {
        g_prefab_param_read_failures.fetch_add(1);
    } else {
        format_prefab_hash(hash, raw_hash_hex, sizeof(raw_hash_hex));
    }

    DeniedPrefabHash denied{};
    bool denied_match = params_ok && find_denied_prefab_hash(hash, &denied);
    const char* match_source = denied_match ? "configured-offset" : "none";
    uintptr_t matched_hash_address = denied_match
        ? locals + g_prefab_hash_offset.load()
        : 0;
    uint32_t matched_frame_pointer_offset = denied_match ? g_locals_offset.load() : 0;
    uint32_t matched_hash_offset = denied_match ? g_prefab_hash_offset.load() : 0;

    if (!denied_match) {
        denied_match = find_denied_prefab_hash_in_frame(
            stack,
            &denied,
            &matched_hash_address,
            &matched_frame_pointer_offset,
            &matched_hash_offset);
        if (denied_match) {
            match_source = "frame-pointer-scan";
            g_prefab_frame_scan_hits.fetch_add(1);
        }
    }

    if (g_trace.load() && (hits <= 40 || denied_match || !params_ok)) {
        append_log(
            "prefab_hit context=0x%p stack=0x%p result=0x%p locals=0x%p raw_hash=%s matched_hash=%s match_source=%s hash_address=0x%p frame_pointer_offset=0x%X hash_offset=0x%X denied_match=%d asset_name=%s enabled=%d block=%d hits=%llu",
            context,
            stack,
            result,
            reinterpret_cast<void*>(locals),
            raw_hash_hex,
            denied.hash_hex,
            match_source,
            reinterpret_cast<void*>(matched_hash_address),
            matched_frame_pointer_offset,
            matched_hash_offset,
            denied_match ? 1 : 0,
            denied.asset_name,
            g_enabled.load() ? 1 : 0,
            g_block.load() ? 1 : 0,
            static_cast<unsigned long long>(hits));
    }

    if (g_enabled.load() && g_block.load() && denied_match) {
        uint32_t context_capabilities = 0;
        if (context_has_capabilities(context, denied.required_capabilities, &context_capabilities)) {
            const uint64_t allows = g_prefab_allows.fetch_add(1) + 1;
            append_prefab_policy_event(
                "allow",
                allows,
                context,
                locals,
                denied.hash_hex,
                denied.asset_name,
                "ContextCapabilitiesSatisfied",
                denied.required_capabilities,
                context_capabilities);
            write_status("prefab-allowed");
            g_passthrough.fetch_add(1);
            if (g_prefab_original) {
                g_prefab_original(context, stack, result);
            }
            return;
        }

        const uint64_t blocks = g_prefab_blocks.fetch_add(1) + 1;
        append_prefab_policy_event(
            "block",
            blocks,
            context,
            locals,
            denied.hash_hex,
            denied.asset_name,
            "PrefabAssetDenied",
            denied.required_capabilities,
            context_capabilities);
        append_log(
            "blocked ServerPastePrefab context=0x%p locals=0x%p prefab_hash=%s asset_name=%s blocks=%llu",
            context,
            reinterpret_cast<void*>(locals),
            denied.hash_hex,
            denied.asset_name,
            static_cast<unsigned long long>(blocks));
        write_status("prefab-blocked");
        return;
    }

    g_passthrough.fetch_add(1);
    if (g_prefab_original) {
        g_prefab_original(context, stack, result);
    }
}

void __fastcall PlacePrefabApplyDetour(
    void* action,
    void* transaction,
    void* context,
    void* target,
    void* errors,
    void* permissions) {
    const uint64_t hits = g_action_prefab_hits.fetch_add(1) + 1;
    uintptr_t payload = 0;
    unsigned char hash[32]{};
    char hash_hex[65]{};
    const bool params_ok = read_place_prefab_action_hash(action, &payload, hash);
    if (!params_ok) {
        g_action_prefab_param_read_failures.fetch_add(1);
    } else {
        format_prefab_hash(hash, hash_hex, sizeof(hash_hex));
    }

    DeniedPrefabHash denied{};
    const bool denied_match = params_ok && find_denied_prefab_hash(hash, &denied);

    if (g_trace.load() && (hits <= 40 || denied_match || !params_ok)) {
        append_log(
            "action_prefab_hit action=0x%p transaction=0x%p context=0x%p target=0x%p errors=0x%p permissions=0x%p payload=0x%p hash=%s denied_match=%d asset_name=%s enabled=%d block=%d hits=%llu",
            action,
            transaction,
            context,
            target,
            errors,
            permissions,
            reinterpret_cast<void*>(payload),
            denied_match ? denied.hash_hex : hash_hex,
            denied_match ? 1 : 0,
            denied.asset_name,
            g_enabled.load() ? 1 : 0,
            g_block.load() ? 1 : 0,
            static_cast<unsigned long long>(hits));
    }

    if (g_enabled.load() && g_block.load() && denied_match) {
        uint32_t context_capabilities = 0;
        if (context_has_capabilities(context, denied.required_capabilities, &context_capabilities)) {
            const uint64_t allows = g_action_prefab_allows.fetch_add(1) + 1;
            append_prefab_policy_event(
                "allow",
                allows,
                context,
                reinterpret_cast<uintptr_t>(action),
                denied.hash_hex,
                denied.asset_name,
                "PlacePrefabActionContextCapabilitiesSatisfied",
                denied.required_capabilities,
                context_capabilities);
            write_status("action-prefab-allowed");
            g_passthrough.fetch_add(1);
            if (g_place_prefab_apply_original) {
                g_place_prefab_apply_original(action, transaction, context, target, errors, permissions);
            }
            return;
        }

        const uint64_t blocks = g_action_prefab_blocks.fetch_add(1) + 1;
        append_prefab_policy_event(
            "block",
            blocks,
            context,
            reinterpret_cast<uintptr_t>(action),
            denied.hash_hex,
            denied.asset_name,
            "PlacePrefabActionDenied",
            denied.required_capabilities,
            context_capabilities);
        append_log(
            "blocked PlacePrefab action=0x%p context=0x%p payload=0x%p prefab_hash=%s asset_name=%s blocks=%llu",
            action,
            context,
            reinterpret_cast<void*>(payload),
            denied.hash_hex,
            denied.asset_name,
            static_cast<unsigned long long>(blocks));
        write_status("action-prefab-blocked");
        return;
    }

    g_action_prefab_allows.fetch_add(1);
    g_passthrough.fetch_add(1);
    if (g_place_prefab_apply_original) {
        g_place_prefab_apply_original(action, transaction, context, target, errors, permissions);
    }
}

void __fastcall PlaceBrickApplyDetour(
    void* action,
    void* transaction,
    void* context,
    void* target,
    void* errors,
    void* permissions) {
    const uint64_t hits = g_action_brick_hits.fetch_add(1) + 1;
    uintptr_t record = 0;
    uintptr_t asset = 0;
    const bool params_ok = resolve_place_brick_action_asset(action, &record, &asset);
    if (!params_ok) {
        g_action_brick_param_read_failures.fetch_add(1);
    }

    DeniedAsset denied{};
    const bool denied_match = params_ok && find_denied_asset(asset, &denied);

    if (g_trace.load() && (hits <= 40 || denied_match || !params_ok)) {
        append_log(
            "action_brick_hit action=0x%p transaction=0x%p context=0x%p target=0x%p errors=0x%p permissions=0x%p record=0x%p asset=0x%p denied_match=%d asset_name=%s params_ok=%d enabled=%d block=%d hits=%llu",
            action,
            transaction,
            context,
            target,
            errors,
            permissions,
            reinterpret_cast<void*>(record),
            reinterpret_cast<void*>(asset),
            denied_match ? 1 : 0,
            denied.name,
            params_ok ? 1 : 0,
            g_enabled.load() ? 1 : 0,
            g_block.load() ? 1 : 0,
            static_cast<unsigned long long>(hits));
    }

    if (g_enabled.load() && g_block.load() && denied_match) {
        uint32_t context_capabilities = 0;
        if (context_has_capabilities(context, denied.required_capabilities, &context_capabilities)) {
            const uint64_t allows = g_action_brick_allows.fetch_add(1) + 1;
            append_policy_event(
                "allow",
                allows,
                context,
                reinterpret_cast<uintptr_t>(action),
                asset,
                denied.name,
                "PlaceBrickActionContextCapabilitiesSatisfied",
                denied.required_capabilities,
                context_capabilities);
            write_status("action-brick-allowed");
            g_passthrough.fetch_add(1);
            if (g_place_brick_apply_original) {
                g_place_brick_apply_original(action, transaction, context, target, errors, permissions);
            }
            return;
        }

        const uint64_t blocks = g_action_brick_blocks.fetch_add(1) + 1;
        append_policy_event(
            "block",
            blocks,
            context,
            reinterpret_cast<uintptr_t>(action),
            asset,
            denied.name,
            "PlaceBrickActionDenied",
            denied.required_capabilities,
            context_capabilities);
        append_log(
            "blocked PlaceBrick action=0x%p context=0x%p record=0x%p asset=0x%p asset_name=%s blocks=%llu",
            action,
            context,
            reinterpret_cast<void*>(record),
            reinterpret_cast<void*>(asset),
            denied.name,
            static_cast<unsigned long long>(blocks));
        write_status("action-brick-blocked");
        return;
    }

    g_action_brick_allows.fetch_add(1);
    g_passthrough.fetch_add(1);
    if (g_place_brick_apply_original) {
        g_place_brick_apply_original(action, transaction, context, target, errors, permissions);
    }
}

bool install_hook() {
    load_control();

    const uintptr_t function = g_function.load();
    const uint32_t func_offset = g_func_offset.load();
    if (function == 0 || func_offset > 0x400) {
        append_log("install skipped function=0x%p func_offset=0x%X", reinterpret_cast<void*>(function), func_offset);
        write_status("missing-function");
        return false;
    }

    const uintptr_t slot_address = function + func_offset;
    if (!is_accessible_memory(slot_address, sizeof(void*))) {
        append_log(
            "install failed inaccessible func slot function=0x%p slot=0x%p",
            reinterpret_cast<void*>(function),
            reinterpret_cast<void*>(slot_address));
        write_status("slot-inaccessible");
        return false;
    }

    void** slot = reinterpret_cast<void**>(slot_address);
    void* current = nullptr;
    std::memcpy(&current, slot, sizeof(current));
    if (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current))) {
        append_log("install failed non-executable current slot=0x%p current=0x%p", slot, current);
        write_status("original-not-executable");
        return false;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect)) {
        append_log("VirtualProtect failed slot=0x%p error=%lu", slot, GetLastError());
        write_status("virtualprotect-failed");
        return false;
    }

    void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&NativeFuncDetour));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

    if (previous == reinterpret_cast<void*>(&NativeFuncDetour)) {
        previous = reinterpret_cast<void*>(g_original);
    }

    g_func_slot = slot;
    g_original = reinterpret_cast<NativeFunc>(previous);
    g_installed.store(true);

    append_log(
        "installed function=0x%p func_slot=0x%p original=0x%p detour=0x%p asset_offset=0x%X enabled=%d block=%d",
        reinterpret_cast<void*>(function),
        slot,
        reinterpret_cast<void*>(g_original),
        reinterpret_cast<void*>(&NativeFuncDetour),
        g_asset_offset.load(),
        g_enabled.load() ? 1 : 0,
        g_block.load() ? 1 : 0);
    write_status("installed");
    return true;
}

bool install_prefab_hook() {
    const uintptr_t function = g_prefab_function.load();
    const uint32_t func_offset = g_prefab_func_offset.load();
    if (function == 0) {
        append_log("prefab install skipped missing function");
        return true;
    }
    if (func_offset > 0x400) {
        append_log("prefab install skipped function=0x%p func_offset=0x%X", reinterpret_cast<void*>(function), func_offset);
        write_status("prefab-missing-function");
        return false;
    }

    const uintptr_t slot_address = function + func_offset;
    if (!is_accessible_memory(slot_address, sizeof(void*))) {
        append_log(
            "prefab install failed inaccessible func slot function=0x%p slot=0x%p",
            reinterpret_cast<void*>(function),
            reinterpret_cast<void*>(slot_address));
        write_status("prefab-slot-inaccessible");
        return false;
    }

    void** slot = reinterpret_cast<void**>(slot_address);
    void* current = nullptr;
    std::memcpy(&current, slot, sizeof(current));
    if (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current))) {
        append_log("prefab install failed non-executable current slot=0x%p current=0x%p", slot, current);
        write_status("prefab-original-not-executable");
        return false;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect)) {
        append_log("prefab VirtualProtect failed slot=0x%p error=%lu", slot, GetLastError());
        write_status("prefab-virtualprotect-failed");
        return false;
    }

    void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&PrefabFuncDetour));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

    if (previous == reinterpret_cast<void*>(&PrefabFuncDetour)) {
        previous = reinterpret_cast<void*>(g_prefab_original);
    }

    g_prefab_func_slot = slot;
    g_prefab_original = reinterpret_cast<NativeFunc>(previous);
    g_prefab_installed.store(true);

    append_log(
        "prefab installed function=0x%p func_slot=0x%p original=0x%p detour=0x%p hash_offset=0x%X enabled=%d block=%d",
        reinterpret_cast<void*>(function),
        slot,
        reinterpret_cast<void*>(g_prefab_original),
        reinterpret_cast<void*>(&PrefabFuncDetour),
        g_prefab_hash_offset.load(),
        g_enabled.load() ? 1 : 0,
        g_block.load() ? 1 : 0);
    write_status("prefab-installed");
    return true;
}

bool install_action_prefab_hook() {
    const uintptr_t method_block = g_place_prefab_method_block.load();
    if (method_block == 0) {
        append_log("action prefab install skipped missing method block");
        return true;
    }

    const uint32_t slot_offset = g_place_prefab_apply_slot_offset.load();
    if (slot_offset > 0x400) {
        append_log(
            "action prefab install skipped method_block=0x%p slot_offset=0x%X",
            reinterpret_cast<void*>(method_block),
            slot_offset);
        write_status("action-prefab-missing-method-block");
        return false;
    }

    const uintptr_t slot_address = method_block + slot_offset;
    if (!is_accessible_memory(slot_address, sizeof(void*))) {
        append_log(
            "action prefab install failed inaccessible slot method_block=0x%p slot=0x%p",
            reinterpret_cast<void*>(method_block),
            reinterpret_cast<void*>(slot_address));
        write_status("action-prefab-slot-inaccessible");
        return false;
    }

    void** slot = reinterpret_cast<void**>(slot_address);
    void* current = nullptr;
    std::memcpy(&current, slot, sizeof(current));
    if (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current))) {
        append_log("action prefab install failed non-executable current slot=0x%p current=0x%p", slot, current);
        write_status("action-prefab-original-not-executable");
        return false;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect)) {
        append_log("action prefab VirtualProtect failed slot=0x%p error=%lu", slot, GetLastError());
        write_status("action-prefab-virtualprotect-failed");
        return false;
    }

    void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&PlacePrefabApplyDetour));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

    if (previous == reinterpret_cast<void*>(&PlacePrefabApplyDetour)) {
        previous = reinterpret_cast<void*>(g_place_prefab_apply_original);
    }

    g_place_prefab_apply_slot = slot;
    g_place_prefab_apply_original = reinterpret_cast<PlacePrefabApplyFunc>(previous);
    g_action_prefab_installed.store(true);

    append_log(
        "action prefab installed method_block=0x%p slot=0x%p original=0x%p detour=0x%p payload_offset=0x%X hash_offset=0x%X enabled=%d block=%d",
        reinterpret_cast<void*>(method_block),
        slot,
        reinterpret_cast<void*>(g_place_prefab_apply_original),
        reinterpret_cast<void*>(&PlacePrefabApplyDetour),
        g_place_prefab_payload_offset.load(),
        g_place_prefab_payload_hash_offset.load(),
        g_enabled.load() ? 1 : 0,
        g_block.load() ? 1 : 0);
    write_status("action-prefab-installed");
    return true;
}

bool install_action_brick_hook() {
    const uintptr_t method_block = g_place_brick_method_block.load();
    if (method_block == 0) {
        append_log("action brick install skipped missing method block");
        return true;
    }

    const uint32_t slot_offset = g_place_brick_apply_slot_offset.load();
    if (slot_offset > 0x400) {
        append_log(
            "action brick install skipped method_block=0x%p slot_offset=0x%X",
            reinterpret_cast<void*>(method_block),
            slot_offset);
        write_status("action-brick-missing-method-block");
        return false;
    }

    const uintptr_t slot_address = method_block + slot_offset;
    if (!is_accessible_memory(slot_address, sizeof(void*))) {
        append_log(
            "action brick install failed inaccessible slot method_block=0x%p slot=0x%p",
            reinterpret_cast<void*>(method_block),
            reinterpret_cast<void*>(slot_address));
        write_status("action-brick-slot-inaccessible");
        return false;
    }

    void** slot = reinterpret_cast<void**>(slot_address);
    void* current = nullptr;
    std::memcpy(&current, slot, sizeof(current));
    if (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current))) {
        append_log("action brick install failed non-executable current slot=0x%p current=0x%p", slot, current);
        write_status("action-brick-original-not-executable");
        return false;
    }

    DWORD old_protect = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect)) {
        append_log("action brick VirtualProtect failed slot=0x%p error=%lu", slot, GetLastError());
        write_status("action-brick-virtualprotect-failed");
        return false;
    }

    void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&PlaceBrickApplyDetour));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

    if (previous == reinterpret_cast<void*>(&PlaceBrickApplyDetour)) {
        previous = reinterpret_cast<void*>(g_place_brick_apply_original);
    }

    g_place_brick_apply_slot = slot;
    g_place_brick_apply_original = reinterpret_cast<ActionApplyFunc>(previous);
    g_action_brick_installed.store(true);

    append_log(
        "action brick installed method_block=0x%p slot=0x%p original=0x%p detour=0x%p ref_offset=0x%X variant_offset=0x%X asset_record_offset=0x%X enabled=%d block=%d",
        reinterpret_cast<void*>(method_block),
        slot,
        reinterpret_cast<void*>(g_place_brick_apply_original),
        reinterpret_cast<void*>(&PlaceBrickApplyDetour),
        g_place_brick_ref_offset.load(),
        g_place_brick_variant_offset.load(),
        g_place_brick_asset_record_offset.load(),
        g_enabled.load() ? 1 : 0,
        g_block.load() ? 1 : 0);
    write_status("action-brick-installed");
    return true;
}

bool install_hooks() {
    load_control();
    const bool placement_ok = g_installed.load() || install_hook();
    const bool prefab_required = g_prefab_function.load() != 0;
    const bool prefab_ok = !prefab_required || g_prefab_installed.load() || install_prefab_hook();
    const bool action_prefab_required = g_place_prefab_method_block.load() != 0;
    const bool action_prefab_ok =
        !action_prefab_required || g_action_prefab_installed.load() || install_action_prefab_hook();
    const bool action_brick_required = g_place_brick_method_block.load() != 0;
    const bool action_brick_ok =
        !action_brick_required || g_action_brick_installed.load() || install_action_brick_hook();
    if (placement_ok && prefab_ok && action_prefab_ok && action_brick_ok) {
        write_status("installed");
    }
    return placement_ok && prefab_ok && action_prefab_ok && action_brick_ok;
}

DWORD WINAPI worker_thread(void*) {
    append_log("worker starting");
    for (int attempt = 0; attempt < 40; ++attempt) {
        if (install_hooks()) {
            break;
        }
        Sleep(500);
    }

    while (true) {
        const bool policy_changed = load_control();
        if (policy_changed && g_installed.load() &&
            (g_prefab_function.load() == 0 || g_prefab_installed.load())) {
            write_status("policy-refreshed");
        }
        Sleep(1000);
    }
    return 0;
}

} // namespace

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        HANDLE thread = CreateThread(nullptr, 0, worker_thread, nullptr, 0, nullptr);
        if (thread) {
            CloseHandle(thread);
        }
    }
    return TRUE;
}
