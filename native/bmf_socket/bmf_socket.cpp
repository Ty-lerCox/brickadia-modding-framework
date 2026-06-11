#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

#include <Helpers/String.hpp>
#include <Mod/CppUserModBase.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Unreal/AActor.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/CoreUObject/UObject/UnrealType.hpp>
#include <Unreal/UObjectGlobals.hpp>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cctype>
#include <deque>
#include <exception>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

using namespace RC;

namespace
{
    std::string json_escape(std::string_view value)
    {
        std::string out;
        out.reserve(value.size() + 8);
        for (char ch : value)
        {
            switch (ch)
            {
            case '\\':
                out += "\\\\";
                break;
            case '"':
                out += "\\\"";
                break;
            case '\r':
                out += "\\r";
                break;
            case '\n':
                out += "\\n";
                break;
            case '\t':
                out += "\\t";
                break;
            default:
                if (static_cast<unsigned char>(ch) < 0x20)
                {
                    out += '?';
                }
                else
                {
                    out += ch;
                }
                break;
            }
        }
        return out;
    }

    bool send_all(SOCKET socket, const std::string& data)
    {
        const char* cursor = data.data();
        int remaining = static_cast<int>(data.size());
        while (remaining > 0)
        {
            const int sent = ::send(socket, cursor, remaining, 0);
            if (sent <= 0)
            {
                return false;
            }
            cursor += sent;
            remaining -= sent;
        }
        return true;
    }

    std::string narrow_string(const StringType& value)
    {
        return to_string(value);
    }

    std::string ascii_lower(std::string value)
    {
        std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
            return static_cast<char>(std::tolower(ch));
        });
        return value;
    }

    std::string trim_ascii(std::string_view value)
    {
        size_t start = 0;
        size_t end = value.size();
        while (start < end && std::isspace(static_cast<unsigned char>(value[start])))
        {
            ++start;
        }
        while (end > start && std::isspace(static_cast<unsigned char>(value[end - 1])))
        {
            --end;
        }
        return std::string(value.substr(start, end - start));
    }

    bool env_flag_enabled(const char* name)
    {
        const char* raw = std::getenv(name);
        if (!raw)
        {
            return false;
        }

        const std::string value = ascii_lower(trim_ascii(raw));
        return value == "1" || value == "true" || value == "yes" || value == "on";
    }

    bool contains_ascii_case_insensitive(std::string_view value, std::string_view needle)
    {
        std::string value_lower = ascii_lower(std::string(value));
        std::string needle_lower = ascii_lower(std::string(needle));
        return value_lower.find(needle_lower) != std::string::npos;
    }

    bool is_accessible_memory(uintptr_t address, size_t bytes)
    {
        MEMORY_BASIC_INFORMATION mbi{};
        if (address == 0 || bytes == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0)
        {
            return false;
        }
        if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS))
        {
            return false;
        }
        const uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
        const uintptr_t region_end = region_start + mbi.RegionSize;
        return address >= region_start && address + bytes >= address && address + bytes <= region_end;
    }

    bool is_executable_memory(uintptr_t address)
    {
        MEMORY_BASIC_INFORMATION mbi{};
        if (address == 0 || VirtualQuery(reinterpret_cast<void*>(address), &mbi, sizeof(mbi)) == 0)
        {
            return false;
        }
        if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS))
        {
            return false;
        }
        const DWORD execute_flags =
            PAGE_EXECUTE | PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE_WRITECOPY;
        return (mbi.Protect & execute_flags) != 0;
    }

    bool parse_uobject_address(std::string_view raw, uintptr_t& address)
    {
        std::string text;
        text.reserve(raw.size());
        for (char ch : raw)
        {
            if (!std::isspace(static_cast<unsigned char>(ch)))
            {
                text.push_back(ch);
            }
        }
        if (text.empty())
        {
            return false;
        }

        if (text.rfind("UObject:", 0) == 0 || text.rfind("uobject:", 0) == 0)
        {
            text = text.substr(text.find(':') + 1);
        }

        int base = 10;
        const char* cursor = text.c_str();
        if (text.rfind("0x", 0) == 0 || text.rfind("0X", 0) == 0)
        {
            base = 16;
            cursor += 2;
        }
        else if (text.find_first_of("ABCDEFabcdef") != std::string::npos)
        {
            base = 16;
        }

        char* end = nullptr;
        const unsigned long long parsed = std::strtoull(cursor, &end, base);
        if (end == cursor || (end && *end != '\0') || parsed == 0)
        {
            return false;
        }
        address = static_cast<uintptr_t>(parsed);
        return address != 0;
    }

    Unreal::UObject* uobject_from_address(std::string_view raw)
    {
        uintptr_t address = 0;
        if (!parse_uobject_address(raw, address))
        {
            return nullptr;
        }
        return reinterpret_cast<Unreal::UObject*>(address);
    }

    bool is_native_location_scan_request(std::string_view raw)
    {
        const std::string text = ascii_lower(trim_ascii(raw));
        return text == "*" || text == "scan" || text == "native-scan";
    }

    bool native_location_scan_enabled()
    {
        return env_flag_enabled("BMF_NATIVE_LOCATION_SCAN");
    }

    bool native_location_name_lookup_enabled()
    {
        return env_flag_enabled("BMF_NATIVE_LOCATION_NAME_LOOKUP");
    }

    bool is_live_uobject(Unreal::UObject* object)
    {
        return object != nullptr &&
               Unreal::UObject::IsReal(object) &&
               !object->HasAnyFlags(Unreal::RF_ClassDefaultObject);
    }

    bool object_class_has_any_cast_flags(Unreal::UObject* object, Unreal::EClassCastFlags flags)
    {
        if (!is_live_uobject(object))
        {
            return false;
        }

        try
        {
            auto object_class = object->GetClassPrivate();
            return object_class && object_class->HasAnyCastFlag(flags);
        }
        catch (...)
        {
            return false;
        }
    }

    bool object_is_actor(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return false;
        }

        try
        {
            return object->IsA<Unreal::AActor>();
        }
        catch (...)
        {
            return false;
        }
    }

    bool object_is_pawn(Unreal::UObject* object)
    {
        return object_class_has_any_cast_flags(object, Unreal::CASTCLASS_APawn);
    }

    std::string object_address_hex(Unreal::UObject* object)
    {
        if (!object)
        {
            return "";
        }

        std::ostringstream out;
        out << "0x" << std::hex << std::uppercase << std::setw(sizeof(uintptr_t) * 2)
            << std::setfill('0') << reinterpret_cast<uintptr_t>(object);
        return out.str();
    }

    std::string object_name(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return "";
        }

        try
        {
            return narrow_string(object->GetName());
        }
        catch (...)
        {
            return "";
        }
    }

    std::string object_full_name(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return "";
        }

        try
        {
            return narrow_string(object->GetFullName());
        }
        catch (...)
        {
            return "";
        }
    }

    std::string object_class_name(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return "";
        }

        try
        {
            auto object_class = object->GetClassPrivate();
            return object_class ? narrow_string(object_class->GetName()) : "";
        }
        catch (...)
        {
            return "";
        }
    }

    std::string object_class_full_name(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return "";
        }

        try
        {
            auto object_class = object->GetClassPrivate();
            return object_class ? narrow_string(object_class->GetFullName()) : "";
        }
        catch (...)
        {
            return "";
        }
    }

    std::string object_class_cast_flags_hex(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return "";
        }

        try
        {
            auto object_class = object->GetClassPrivate();
            if (!object_class)
            {
                return "";
            }

            std::ostringstream out;
            out << "0x" << std::hex << std::uppercase << object_class->GetClassCastFlags();
            return out.str();
        }
        catch (...)
        {
            return "";
        }
    }

    std::string normalize_object_lookup_name(std::string_view raw)
    {
        std::string text = trim_ascii(raw);
        const std::string lowered = ascii_lower(text);
        for (std::string_view prefix : {std::string_view("name:"), std::string_view("object:"), std::string_view("controller:")})
        {
            if (lowered.rfind(prefix, 0) == 0)
            {
                text = trim_ascii(std::string_view(text).substr(prefix.size()));
                break;
            }
        }
        return text;
    }

    bool object_matches_lookup_name(Unreal::UObject* object, std::string_view raw_query)
    {
        if (!is_live_uobject(object))
        {
            return false;
        }

        const std::string query = normalize_object_lookup_name(raw_query);
        if (query.empty())
        {
            return false;
        }
        const std::string query_lower = ascii_lower(query);

        try
        {
            const std::string object_name = narrow_string(object->GetName());
            if (ascii_lower(object_name) == query_lower)
            {
                return true;
            }

            const std::string object_full_name = narrow_string(object->GetFullName());
            const std::string object_full_name_lower = ascii_lower(object_full_name);
            if (object_full_name_lower == query_lower ||
                object_full_name_lower.find("." + query_lower) != std::string::npos ||
                object_full_name_lower.find(":" + query_lower) != std::string::npos)
            {
                return true;
            }
        }
        catch (...)
        {
            return false;
        }

        return false;
    }

    Unreal::UObject* uobject_from_address_or_name(std::string_view raw)
    {
        if (Unreal::UObject* object = uobject_from_address(raw))
        {
            return object;
        }

        if (!native_location_name_lookup_enabled())
        {
            return nullptr;
        }

        Unreal::UObject* found = nullptr;
        Unreal::UObjectGlobals::ForEachUObject([&](Unreal::UObject* object, int32_t, int32_t) {
            if (!found && object_matches_lookup_name(object, raw))
            {
                found = object;
            }
            return LoopAction::Continue;
        });
        return found;
    }

    Unreal::FProperty* get_class_property_by_name_in_chain(Unreal::UObject* object, Unreal::FName property_name)
    {
        if (!object)
        {
            return nullptr;
        }

        auto object_class = object->GetClassPrivate();
        if (!object_class)
        {
            return nullptr;
        }

        for (Unreal::FProperty* property : Unreal::TFieldRange<Unreal::FProperty>(
                 object_class,
                 Unreal::EFieldIterationFlags::IncludeSuper | Unreal::EFieldIterationFlags::IncludeDeprecated))
        {
            if (property && property->GetFName().Equals(property_name))
            {
                return property;
            }
        }

        return nullptr;
    }

    Unreal::UObject* get_object_property(Unreal::UObject* object, const CharType* property_name)
    {
        if (!is_live_uobject(object) || !property_name)
        {
            return nullptr;
        }

        try
        {
            const Unreal::FName wanted_property_name{property_name, Unreal::FNAME_Find};
            Unreal::FProperty* property = get_class_property_by_name_in_chain(object, wanted_property_name);
            if (!property)
            {
                return nullptr;
            }

            auto value = property->ContainerPtrToValuePtr<Unreal::UObject*>(object);
            if (!value || !is_live_uobject(*value))
            {
                return nullptr;
            }
            return *value;
        }
        catch (...)
        {
            return nullptr;
        }
    }

    bool read_vector_property(Unreal::UObject* object, const CharType* property_name, Unreal::FVector& out_vector)
    {
        if (!is_live_uobject(object) || !property_name)
        {
            return false;
        }

        try
        {
            const Unreal::FName wanted_property_name{property_name, Unreal::FNAME_Find};
            Unreal::FProperty* property = get_class_property_by_name_in_chain(object, wanted_property_name);
            if (!property)
            {
                return false;
            }

            auto value = property->ContainerPtrToValuePtr<Unreal::FVector>(object);
            if (!value)
            {
                return false;
            }

            const double x = value->X();
            const double y = value->Y();
            const double z = value->Z();
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z))
            {
                return false;
            }

            out_vector = *value;
            return true;
        }
        catch (...)
        {
            return false;
        }
    }

    bool read_transform_translation_property(Unreal::UObject* object,
                                             const CharType* property_name,
                                             Unreal::FVector& out_vector)
    {
        if (!is_live_uobject(object) || !property_name)
        {
            return false;
        }

        try
        {
            const Unreal::FName wanted_property_name{property_name, Unreal::FNAME_Find};
            Unreal::FProperty* property = get_class_property_by_name_in_chain(object, wanted_property_name);
            if (!property)
            {
                return false;
            }

            auto value = property->ContainerPtrToValuePtr<Unreal::FTransform>(object);
            if (!value)
            {
                return false;
            }

            Unreal::FVector vector = value->GetTranslation();
            const double x = vector.X();
            const double y = vector.Y();
            const double z = vector.Z();
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z))
            {
                return false;
            }

            out_vector = vector;
            return true;
        }
        catch (...)
        {
            return false;
        }
    }

    bool try_actor_k2_location(Unreal::UObject* pawn, Unreal::FVector& out_vector)
    {
        if (!is_live_uobject(pawn))
        {
            return false;
        }

        try
        {
            auto actor = static_cast<Unreal::AActor*>(pawn);
            const Unreal::FVector vector = actor->K2_GetActorLocation();
            const double x = vector.X();
            const double y = vector.Y();
            const double z = vector.Z();
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z))
            {
                return false;
            }

            out_vector = vector;
            return true;
        }
        catch (...)
        {
            return false;
        }
    }

    bool try_actor_root_component_location(Unreal::UObject* pawn,
                                           Unreal::FVector& out_vector,
                                           std::string& method)
    {
        Unreal::UObject* root_component = get_object_property(pawn, STR("RootComponent"));
        if (!is_live_uobject(root_component))
        {
            return false;
        }

        if (read_transform_translation_property(root_component, STR("ComponentToWorld"), out_vector))
        {
            method = ".root_component.ComponentToWorld";
            return true;
        }

        if (read_vector_property(root_component, STR("RelativeLocation"), out_vector))
        {
            method = ".root_component.RelativeLocation";
            return true;
        }

        return false;
    }

    void write_object_reference_fields(std::ostringstream& out, std::string_view prefix, Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return;
        }

        out << prefix << "_address=" << json_escape(object_address_hex(object)) << "\n"
            << prefix << "_name=" << json_escape(object_name(object)) << "\n"
            << prefix << "_full_name=" << json_escape(object_full_name(object)) << "\n"
            << prefix << "_class=" << json_escape(object_class_name(object)) << "\n"
            << prefix << "_class_full_name=" << json_escape(object_class_full_name(object)) << "\n";
    }

    bool property_is_object_reference(Unreal::FProperty* property)
    {
        if (!property)
        {
            return false;
        }

        try
        {
            auto field_class = property->GetClass();
            return field_class.IsValid() && field_class.HasAllCastFlags(Unreal::CASTCLASS_FObjectPropertyBase);
        }
        catch (...)
        {
            return false;
        }
    }

    void write_bounded_object_property_references(std::ostringstream& out, Unreal::UObject* object, int max_refs)
    {
        if (!is_live_uobject(object))
        {
            return;
        }

        auto object_class = object->GetClassPrivate();
        if (!object_class)
        {
            return;
        }

        int visited = 0;
        int emitted = 0;
        int errors = 0;
        for (Unreal::FProperty* property : Unreal::TFieldRange<Unreal::FProperty>(
                 object_class,
                 Unreal::EFieldIterationFlags::IncludeSuper | Unreal::EFieldIterationFlags::IncludeDeprecated))
        {
            ++visited;
            if (!property_is_object_reference(property))
            {
                continue;
            }

            try
            {
                auto value = property->ContainerPtrToValuePtr<Unreal::UObject*>(object);
                if (!value || !is_live_uobject(*value))
                {
                    continue;
                }

                ++emitted;
                const std::string prefix = std::string("ref_") + std::to_string(emitted);
                out << prefix << "_property=" << json_escape(narrow_string(property->GetName())) << "\n";
                write_object_reference_fields(out, prefix, *value);

                if (emitted >= max_refs)
                {
                    break;
                }
            }
            catch (...)
            {
                ++errors;
            }
        }

        out << "object_ref_properties_visited=" << visited << "\n"
            << "object_ref_properties_emitted=" << emitted << "\n"
            << "object_ref_properties_errors=" << errors << "\n"
            << "object_ref_properties_truncated=" << (emitted >= max_refs ? "true" : "false") << "\n";
    }

    std::string build_native_uobject_description_text(std::string_view source_address)
    {
        std::ostringstream out;
        out << "Native UObject description\n"
            << "source=BMFSocketDescribeUObject\n"
            << "requested_address=" << json_escape(source_address) << "\n";

        uintptr_t parsed_source_address = 0;
        if (!parse_uobject_address(source_address, parsed_source_address))
        {
            out << "ok=false\n"
                << "detail=source address must be a non-zero UObject pointer\n";
            return out.str();
        }

        Unreal::UObject* source = reinterpret_cast<Unreal::UObject*>(parsed_source_address);
        if (!is_live_uobject(source))
        {
            out << "ok=false\n"
                << "detail=source address does not point to a live UObject\n";
            return out.str();
        }

        out << "ok=true\n";
        write_object_reference_fields(out, "object", source);
        out << "object_class_cast_flags=" << json_escape(object_class_cast_flags_hex(source)) << "\n"
            << "object_is_actor=" << (object_is_actor(source) ? "true" : "false") << "\n"
            << "object_is_pawn=" << (object_is_pawn(source) ? "true" : "false") << "\n";

        Unreal::FVector location{};
        std::string location_method;
        if (try_actor_k2_location(source, location))
        {
            location_method = ".K2_GetActorLocation";
        }
        else
        {
            try_actor_root_component_location(source, location, location_method);
        }
        if (!location_method.empty())
        {
            out << std::setprecision(17)
                << "object_location_method=" << json_escape(location_method) << "\n"
                << "object_location_x=" << static_cast<double>(location.X()) << "\n"
                << "object_location_y=" << static_cast<double>(location.Y()) << "\n"
                << "object_location_z=" << static_cast<double>(location.Z()) << "\n";
        }

        struct PropertyProbe
        {
            const char* output_name;
            const CharType* property_name;
        };

        const PropertyProbe probes[] = {
            {"owner", STR("Owner")},
            {"instigator", STR("Instigator")},
            {"instigator_controller", STR("InstigatorController")},
            {"controller", STR("Controller")},
            {"player_state", STR("PlayerState")},
            {"pawn", STR("Pawn")},
            {"acknowledged_pawn", STR("AcknowledgedPawn")},
            {"weapon", STR("Weapon")},
            {"item", STR("Item")},
            {"tool", STR("Tool")},
            {"target", STR("Target")},
        };

        for (const PropertyProbe& probe : probes)
        {
            if (Unreal::UObject* value = get_object_property(source, probe.property_name))
            {
                write_object_reference_fields(out, probe.output_name, value);
            }
        }

        write_bounded_object_property_references(out, source, 32);

        return out.str();
    }

    using NativeFunc = void(__fastcall*)(void* context, void* stack, void* result);

    constexpr uintptr_t kTreeCutFuncOffset = 0xD8;
    constexpr uintptr_t kTreeCutStackLocalsOffset = 0x28;
    constexpr size_t kTreeCutParamBytes = sizeof(double) * 7;
    constexpr double kTreeCutTargetResolveRadius = 650.0;
    constexpr double kTreeCutTargetResolveRadiusSq =
        kTreeCutTargetResolveRadius * kTreeCutTargetResolveRadius;
    constexpr size_t kTreeCutTargetCacheMaxCandidates = 512;

    std::atomic<bool> g_treecut_enabled{false};
    std::atomic<bool> g_treecut_installed{false};
    std::atomic<uint64_t> g_treecut_hits{0};
    std::atomic<uint64_t> g_treecut_events{0};
    std::atomic<uint64_t> g_treecut_verified_handaxe_hits{0};
    std::atomic<uint64_t> g_treecut_rejected_non_handaxe{0};
    std::atomic<uint64_t> g_treecut_param_failures{0};
    std::atomic<uint64_t> g_treecut_queue_drops{0};
    std::atomic<uint64_t> g_treecut_target_resolve_attempts{0};
    std::atomic<uint64_t> g_treecut_target_resolve_hits{0};
    std::atomic<uint64_t> g_treecut_target_resolve_misses{0};
    std::atomic<uint64_t> g_treecut_target_cache_refreshes{0};
    std::atomic<uint64_t> g_treecut_target_cache_scanned_objects{0};
    std::atomic<uint64_t> g_treecut_target_cache_errors{0};
    std::atomic<uint64_t> g_treecut_target_cache_last_refresh_ms{0};
    std::atomic<uint64_t> g_treecut_console_tag_hits{0};
    std::atomic<uint64_t> g_treecut_console_tag_misses{0};
    std::atomic<uintptr_t> g_treecut_function{0};
    std::atomic<uintptr_t> g_treecut_slot{0};
    std::atomic<uintptr_t> g_treecut_original{0};
    std::atomic<uintptr_t> g_treecut_handaxe_class{0};
    std::atomic<bool> g_treecut_handaxe_class_resolved{false};
    std::atomic<bool> g_treecut_handaxe_class_attempted{false};
    std::atomic<uintptr_t> g_treecut_last_context{0};
    std::atomic<uintptr_t> g_treecut_last_context_class{0};
    std::mutex g_treecut_mutex;
    std::deque<std::string> g_treecut_queue;
    std::string g_treecut_last_error;
    std::string g_treecut_last_item_type;
    std::string g_treecut_last_reject_reason;
    std::string g_treecut_handaxe_class_source;
    std::string g_treecut_handaxe_class_detail;
    std::string g_treecut_last_target_name;
    std::string g_treecut_last_target_full_name;
    std::string g_treecut_last_target_class;
    std::string g_treecut_last_target_detail;
    std::string g_treecut_last_console_tag;
    std::string g_treecut_last_console_tag_source;

    struct TreeCutTargetCandidate
    {
        Unreal::UObject* actor{nullptr};
        std::string address;
        std::string name;
        std::string full_name;
        std::string class_name;
        std::string class_full_name;
        Unreal::FVector location{};
        std::string location_method;
        std::string console_tag;
        std::string console_tag_source;
        std::string console_tag_source_object;
        bool tagged_component{false};
    };

    std::vector<TreeCutTargetCandidate> g_treecut_target_cache;

    void __fastcall treecut_native_detour(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_0(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_1(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_2(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_3(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_4(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_5(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_6(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_7(void* context, void* stack, void* result);
    void __fastcall treecut_probe_detour_8(void* context, void* stack, void* result);

    std::string pointer_hex(uintptr_t value)
    {
        if (value == 0)
        {
            return "";
        }
        std::ostringstream out;
        out << "0x" << std::hex << std::uppercase << std::setw(sizeof(uintptr_t) * 2)
            << std::setfill('0') << value;
        return out.str();
    }

    std::string system_utc_iso()
    {
        SYSTEMTIME st{};
        GetSystemTime(&st);
        char buffer[64]{};
        std::snprintf(
            buffer,
            sizeof(buffer),
            "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
            st.wYear,
            st.wMonth,
            st.wDay,
            st.wHour,
            st.wMinute,
            st.wSecond,
            st.wMilliseconds);
        return std::string(buffer);
    }

    bool read_treecut_params(void* stack, uintptr_t& out_locals, double out_values[7])
    {
        if (!stack || !out_values)
        {
            return false;
        }

        uintptr_t locals = 0;
        __try
        {
            std::memcpy(&locals, static_cast<unsigned char*>(stack) + kTreeCutStackLocalsOffset, sizeof(uintptr_t));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }

        if (locals == 0 || !is_accessible_memory(locals, kTreeCutParamBytes))
        {
            return false;
        }

        __try
        {
            std::memcpy(out_values, reinterpret_cast<void*>(locals), kTreeCutParamBytes);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }

        for (int index = 0; index < 7; ++index)
        {
            if (!std::isfinite(out_values[index]))
            {
                return false;
            }
        }

        out_locals = locals;
        return true;
    }

    bool read_process_event_locals(void* stack, uintptr_t& out_locals)
    {
        if (!stack)
        {
            return false;
        }

        uintptr_t locals = 0;
        __try
        {
            std::memcpy(&locals, static_cast<unsigned char*>(stack) + kTreeCutStackLocalsOffset, sizeof(uintptr_t));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }

        if (locals == 0)
        {
            return false;
        }

        out_locals = locals;
        return true;
    }

    Unreal::UObject* read_uobject_at(uintptr_t address)
    {
        if (!is_accessible_memory(address, sizeof(uintptr_t)))
        {
            return nullptr;
        }

        uintptr_t value = 0;
        __try
        {
            std::memcpy(&value, reinterpret_cast<void*>(address), sizeof(value));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return nullptr;
        }

        auto* object = reinterpret_cast<Unreal::UObject*>(value);
        return is_live_uobject(object) ? object : nullptr;
    }

    bool read_u64_at(uintptr_t address, uint64_t& out_value)
    {
        if (!is_accessible_memory(address, sizeof(uint64_t)))
        {
            return false;
        }

        __try
        {
            std::memcpy(&out_value, reinterpret_cast<void*>(address), sizeof(out_value));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    std::string hex_u64(uint64_t value)
    {
        std::ostringstream out;
        out << "0x" << std::uppercase << std::hex << std::setw(16) << std::setfill('0') << value;
        return out.str();
    }

    bool read_i32_at(uintptr_t address, int32_t& out_value)
    {
        if (!is_accessible_memory(address, sizeof(int32_t)))
        {
            return false;
        }

        __try
        {
            std::memcpy(&out_value, reinterpret_cast<void*>(address), sizeof(out_value));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    bool read_u32_at(uintptr_t address, uint32_t& out_value)
    {
        if (!is_accessible_memory(address, sizeof(uint32_t)))
        {
            return false;
        }

        __try
        {
            std::memcpy(&out_value, reinterpret_cast<void*>(address), sizeof(out_value));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    bool read_u8_at(uintptr_t address, uint8_t& out_value)
    {
        if (!is_accessible_memory(address, sizeof(uint8_t)))
        {
            return false;
        }

        __try
        {
            std::memcpy(&out_value, reinterpret_cast<void*>(address), sizeof(out_value));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    bool write_u8_at(uintptr_t address, uint8_t value)
    {
        if (!is_accessible_memory(address, sizeof(uint8_t)))
        {
            return false;
        }

        __try
        {
            *reinterpret_cast<uint8_t*>(address) = value;
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    bool read_utf16_ascii_string(uintptr_t address, int32_t length, std::string& out_value)
    {
        if (address == 0 || length <= 0 || length > 512)
        {
            return false;
        }
        const size_t bytes = static_cast<size_t>(length) * sizeof(wchar_t);
        if (!is_accessible_memory(address, bytes))
        {
            return false;
        }

        std::string text;
        text.reserve(static_cast<size_t>(length));
        const wchar_t* chars = reinterpret_cast<const wchar_t*>(address);
        for (int32_t index = 0; index < length; ++index)
        {
            const wchar_t ch = chars[index];
            if (ch == 0)
            {
                break;
            }
            if (ch < 0x20 || ch > 0x7e)
            {
                return false;
            }
            text.push_back(static_cast<char>(ch));
        }

        text = trim_ascii(text);
        if (text.empty())
        {
            return false;
        }
        out_value = std::move(text);
        return true;
    }

    bool read_ansi_ascii_string(uintptr_t address, int32_t length, std::string& out_value)
    {
        if (address == 0 || length <= 0 || length > 512 || !is_accessible_memory(address, static_cast<size_t>(length)))
        {
            return false;
        }

        std::string text;
        text.reserve(static_cast<size_t>(length));
        const char* chars = reinterpret_cast<const char*>(address);
        for (int32_t index = 0; index < length; ++index)
        {
            const unsigned char ch = static_cast<unsigned char>(chars[index]);
            if (ch == 0)
            {
                break;
            }
            if (ch < 0x20 || ch > 0x7e)
            {
                return false;
            }
            text.push_back(static_cast<char>(ch));
        }

        text = trim_ascii(text);
        if (text.empty())
        {
            return false;
        }
        out_value = std::move(text);
        return true;
    }

    bool is_console_tag_candidate(std::string_view raw, bool allow_plain)
    {
        const std::string text = trim_ascii(raw);
        if (text.empty() || text.size() > 128)
        {
            return false;
        }

        bool has_colon = false;
        for (unsigned char ch : text)
        {
            if (ch == ':')
            {
                has_colon = true;
                continue;
            }
            if (!(std::isalnum(ch) || ch == '_' || ch == '-' || ch == '.'))
            {
                return false;
            }
        }
        return allow_plain || has_colon;
    }

    void push_console_tag_candidate(std::vector<std::string>& tags, std::string_view raw, bool allow_plain)
    {
        const std::string text = trim_ascii(raw);
        if (!is_console_tag_candidate(text, allow_plain))
        {
            return;
        }
        for (const std::string& existing : tags)
        {
            if (existing == text)
            {
                return;
            }
        }
        tags.push_back(text);
    }

    bool treecut_console_tag_is_tree_id(std::string_view raw)
    {
        const std::string text = ascii_lower(trim_ascii(raw));
        return text.rfind("treeid:", 0) == 0 || text.rfind("choptree:", 0) == 0;
    }

    std::string treecut_first_tree_id_console_tag(const std::vector<std::string>& tags)
    {
        for (const std::string& tag : tags)
        {
            if (treecut_console_tag_is_tree_id(tag))
            {
                return tag;
            }
        }
        return "";
    }

    void scan_fstring_like_console_tags(uintptr_t base, uint32_t bytes, std::vector<std::string>& tags, bool allow_plain)
    {
        if (base == 0 || bytes < 16 || !is_accessible_memory(base, bytes))
        {
            return;
        }

        const uint32_t max_offset = bytes > 16 ? bytes - 16 : 0;
        for (uint32_t offset = 0; offset <= max_offset; offset += 4)
        {
            uintptr_t data_ptr = 0;
            int32_t len = 0;
            int32_t max = 0;
            if (!read_u64_at(base + offset, data_ptr) ||
                !read_i32_at(base + offset + 8, len) ||
                !read_i32_at(base + offset + 12, max))
            {
                continue;
            }
            if (data_ptr == 0 || len <= 0 || len > 512 || max < len || max > 4096)
            {
                continue;
            }

            std::string text;
            if (read_utf16_ascii_string(data_ptr, len, text) ||
                read_ansi_ascii_string(data_ptr, len, text))
            {
                push_console_tag_candidate(tags, text, allow_plain);
            }
        }
    }

    struct TreeCutConsoleTagInfo
    {
        std::vector<std::string> tags;
        std::string source;
        std::string source_object;
    };

    void treecut_note_console_tag_source(TreeCutConsoleTagInfo& info, std::string_view source, Unreal::UObject* object = nullptr)
    {
        if (info.source.empty())
        {
            info.source = std::string(source);
        }
        if (info.source_object.empty() && is_live_uobject(object))
        {
            info.source_object = object_address_hex(object);
        }
    }

    std::string compact_object_label(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return "";
        }

        std::ostringstream out;
        out << object_address_hex(object);

        const std::string name = object_name(object);
        if (!name.empty())
        {
            out << " name=" << name;
        }

        const std::string full_name = object_full_name(object);
        if (!full_name.empty() && full_name != name)
        {
            out << " full=" << full_name;
        }

        const std::string class_name = object_class_name(object);
        if (!class_name.empty())
        {
            out << " class=" << class_name;
        }

        return out.str();
    }

    bool treecut_read_console_tag_property(Unreal::UObject* object, std::vector<std::string>& tags)
    {
        if (!is_live_uobject(object))
        {
            return false;
        }

        const size_t before = tags.size();
        try
        {
            const Unreal::FName wanted_property_name{STR("ConsoleTag"), Unreal::FNAME_Find};
            Unreal::FProperty* property = get_class_property_by_name_in_chain(object, wanted_property_name);
            if (!property)
            {
                return false;
            }

            uint8_t* value = property->ContainerPtrToValuePtr<uint8_t>(object);
            if (!value)
            {
                return false;
            }

            scan_fstring_like_console_tags(reinterpret_cast<uintptr_t>(value), 64, tags, true);
        }
        catch (...)
        {
            return false;
        }
        return tags.size() > before;
    }

    void treecut_collect_console_tags_from_object(TreeCutConsoleTagInfo& info,
                                                  Unreal::UObject* object,
                                                  std::string_view source,
                                                  int depth)
    {
        if (!is_live_uobject(object))
        {
            return;
        }

        const size_t before = info.tags.size();
        if (treecut_read_console_tag_property(object, info.tags) && info.tags.size() > before)
        {
            treecut_note_console_tag_source(info, source, object);
        }

        if (depth <= 0)
        {
            return;
        }

        int visited_refs = 0;
        try
        {
            for (Unreal::FProperty* property : Unreal::TFieldRange<Unreal::FProperty>(
                     object->GetClassPrivate(),
                     Unreal::EFieldIterationFlags::IncludeSuper | Unreal::EFieldIterationFlags::IncludeDeprecated))
            {
                if (!property || !property_is_object_reference(property))
                {
                    continue;
                }
                if (visited_refs++ >= 16)
                {
                    break;
                }

                auto value = property->ContainerPtrToValuePtr<Unreal::UObject*>(object);
                if (!value || !is_live_uobject(*value) || *value == object)
                {
                    continue;
                }

                const std::string property_name = narrow_string(property->GetName());
                const std::string child_name = object_name(*value);
                const std::string child_class = object_class_name(*value);
                const bool likely_component =
                    contains_ascii_case_insensitive(property_name, "component") ||
                    contains_ascii_case_insensitive(property_name, "interact") ||
                    contains_ascii_case_insensitive(child_name, "component") ||
                    contains_ascii_case_insensitive(child_name, "interact") ||
                    contains_ascii_case_insensitive(child_class, "component") ||
                    contains_ascii_case_insensitive(child_class, "interact");
                if (!likely_component)
                {
                    continue;
                }

                const size_t child_before = info.tags.size();
                treecut_collect_console_tags_from_object(
                    info,
                    *value,
                    std::string(source) + "." + property_name,
                    depth - 1);
                if (info.tags.size() > child_before && info.source.empty())
                {
                    treecut_note_console_tag_source(info, std::string(source) + "." + property_name, *value);
                }
            }
        }
        catch (...)
        {
        }
    }

    void treecut_collect_console_tags_from_locals(uintptr_t locals, TreeCutConsoleTagInfo& info)
    {
        if (locals == 0)
        {
            return;
        }

        const size_t before_scan = info.tags.size();
        scan_fstring_like_console_tags(locals, 0x300, info.tags, false);
        if (info.tags.size() > before_scan)
        {
            treecut_note_console_tag_source(info, "locals-fstring");
        }

        constexpr uintptr_t object_offsets[] = {
            0x0,
            0x8,
            0x10,
            0x18,
            0x20,
            0x28,
            0x30,
            0x38,
            0xB0,
            0xB8,
            0xD8,
            0x68 + 0xB0,
            0x68 + 0xB8,
            0x68 + 0xD8,
        };

        for (uintptr_t offset : object_offsets)
        {
            Unreal::UObject* object = read_uobject_at(locals + offset);
            if (!is_live_uobject(object))
            {
                continue;
            }

            std::ostringstream source;
            source << "locals+0x" << std::uppercase << std::hex << offset;
            const size_t before_object = info.tags.size();
            treecut_collect_console_tags_from_object(info, object, source.str(), 1);
            if (info.tags.size() > before_object)
            {
                treecut_note_console_tag_source(info, source.str(), object);
            }
        }
    }

    void treecut_record_console_tag_info(const TreeCutConsoleTagInfo& info)
    {
        if (info.tags.empty())
        {
            g_treecut_console_tag_misses.fetch_add(1);
            return;
        }

        g_treecut_console_tag_hits.fetch_add(1);
        std::lock_guard lock(g_treecut_mutex);
        g_treecut_last_console_tag = info.tags.front();
        g_treecut_last_console_tag_source = info.source;
    }

    void write_treecut_console_tags_json(std::ostringstream& out, const TreeCutConsoleTagInfo& info)
    {
        if (info.tags.empty())
        {
            out << ",\"consoleTagResolved\":false";
            return;
        }

        out << ",\"consoleTagResolved\":true"
            << ",\"consoleTag\":\"" << json_escape(info.tags.front()) << "\""
            << ",\"consoleTagSource\":\"" << json_escape(info.source) << "\"";
        if (!info.source_object.empty())
        {
            out << ",\"consoleTagSourceObject\":\"" << json_escape(info.source_object) << "\"";
        }

        out << ",\"consoleTags\":[";
        for (size_t index = 0; index < info.tags.size(); ++index)
        {
            if (index > 0)
            {
                out << ",";
            }
            out << "\"" << json_escape(info.tags[index]) << "\"";
        }
        out << "]"
            << ",\"hitTags\":[";
        for (size_t index = 0; index < info.tags.size(); ++index)
        {
            if (index > 0)
            {
                out << ",";
            }
            out << "\"" << json_escape(info.tags[index]) << "\"";
        }
        out << "]";
    }

    Unreal::UObject* resolve_hit_owner(Unreal::UObject* context)
    {
        Unreal::UObject* owner = get_object_property(context, STR("Owner"));
        if (is_live_uobject(owner))
        {
            return owner;
        }
        return nullptr;
    }

    Unreal::UObject* resolve_hit_pawn(Unreal::UObject* context, Unreal::UObject* owner)
    {
        for (Unreal::UObject* candidate_source : {owner, context})
        {
            if (!is_live_uobject(candidate_source))
            {
                continue;
            }
            for (const CharType* property_name : {STR("Pawn"), STR("AcknowledgedPawn"), STR("Instigator")})
            {
                Unreal::UObject* pawn = get_object_property(candidate_source, property_name);
                if (is_live_uobject(pawn))
                {
                    return pawn;
                }
            }
        }
        return nullptr;
    }

    Unreal::UObject* resolve_hit_player_state(Unreal::UObject* owner, Unreal::UObject* pawn)
    {
        for (Unreal::UObject* candidate_source : {owner, pawn})
        {
            if (!is_live_uobject(candidate_source))
            {
                continue;
            }
            Unreal::UObject* player_state = get_object_property(candidate_source, STR("PlayerState"));
            if (is_live_uobject(player_state))
            {
                return player_state;
            }
        }
        return nullptr;
    }

    Unreal::UObject* find_treecut_melee_function()
    {
        try
        {
            if (auto* function = Unreal::UObjectGlobals::FindObject(
                    STR("Function"),
                    STR("MulticastReplicateAcceleratedMeleeExplosion")))
            {
                return function;
            }
        }
        catch (...)
        {
        }

        for (const CharType* candidate : {
                 STR("/Script/Brickadia.BRWeaponBase:MulticastReplicateAcceleratedMeleeExplosion"),
                 STR("/Script/Brickadia.BRWeaponBase.MulticastReplicateAcceleratedMeleeExplosion"),
             })
        {
            try
            {
                if (auto* function = Unreal::UObjectGlobals::StaticFindObject(nullptr, nullptr, candidate))
                {
                    return function;
                }
            }
            catch (...)
            {
            }
        }
        return nullptr;
    }

    Unreal::UClass* uobject_as_uclass(Unreal::UObject* object)
    {
        if (!is_live_uobject(object))
        {
            return nullptr;
        }

        try
        {
            if (object->IsA<Unreal::UClass>())
            {
                return static_cast<Unreal::UClass*>(object);
            }
        }
        catch (...)
        {
        }

        try
        {
            auto object_class = object->GetClassPrivate();
            if (object_class && object_class->HasAnyCastFlag(Unreal::CASTCLASS_UClass))
            {
                return static_cast<Unreal::UClass*>(object);
            }
        }
        catch (...)
        {
        }
        return nullptr;
    }

    void treecut_cache_handaxe_class_unlocked(Unreal::UClass* candidate, std::string source, std::string detail)
    {
        g_treecut_handaxe_class.store(reinterpret_cast<uintptr_t>(candidate));
        g_treecut_handaxe_class_resolved.store(candidate != nullptr);
        g_treecut_handaxe_class_attempted.store(true);
        g_treecut_handaxe_class_source = std::move(source);
        g_treecut_handaxe_class_detail = std::move(detail);
        g_treecut_last_error = candidate ? "" : g_treecut_handaxe_class_detail;
    }

    Unreal::UClass* find_treecut_handaxe_class_candidate(const CharType* class_kind, const CharType* object_name)
    {
        if (!class_kind || !object_name)
        {
            return nullptr;
        }

        try
        {
            if (Unreal::UObject* object = Unreal::UObjectGlobals::FindObject(class_kind, object_name))
            {
                if (Unreal::UClass* class_object = uobject_as_uclass(object))
                {
                    return class_object;
                }
            }
        }
        catch (...)
        {
        }

        try
        {
            if (Unreal::UObject* object = Unreal::UObjectGlobals::StaticFindObject(nullptr, nullptr, object_name))
            {
                if (Unreal::UClass* class_object = uobject_as_uclass(object))
                {
                    return class_object;
                }
            }
        }
        catch (...)
        {
        }
        return nullptr;
    }

    bool set_treecut_handaxe_class_from_address(std::string_view source_address, std::string_view source_label)
    {
        const std::string label = source_label.empty() ? std::string("address") : std::string(source_label);
        uintptr_t parsed_address = 0;
        if (!parse_uobject_address(source_address, parsed_address))
        {
            std::lock_guard lock(g_treecut_mutex);
            treecut_cache_handaxe_class_unlocked(
                nullptr,
                label,
                "handaxe class address must be a non-zero UObject pointer");
            return false;
        }

        Unreal::UObject* object = reinterpret_cast<Unreal::UObject*>(parsed_address);
        if (!is_live_uobject(object))
        {
            std::lock_guard lock(g_treecut_mutex);
            treecut_cache_handaxe_class_unlocked(
                nullptr,
                label,
                "handaxe class address does not point to a live UObject");
            return false;
        }

        Unreal::UClass* class_object = uobject_as_uclass(object);
        if (!class_object)
        {
            std::lock_guard lock(g_treecut_mutex);
            treecut_cache_handaxe_class_unlocked(
                nullptr,
                label,
                "handaxe class address is live but is not a UClass");
            return false;
        }

        std::lock_guard lock(g_treecut_mutex);
        treecut_cache_handaxe_class_unlocked(
            class_object,
            label,
            "handaxe class accepted from explicit address");
        return true;
    }

    Unreal::UClass* resolve_treecut_handaxe_class()
    {
        if (const uintptr_t cached = g_treecut_handaxe_class.load())
        {
            return reinterpret_cast<Unreal::UClass*>(cached);
        }

        std::lock_guard lock(g_treecut_mutex);
        if (const uintptr_t cached = g_treecut_handaxe_class.load())
        {
            return reinterpret_cast<Unreal::UClass*>(cached);
        }

        struct CandidateName
        {
            const CharType* name;
            const char* label;
        };

        struct CandidateKind
        {
            const CharType* kind;
            const char* label;
        };

        const CandidateName names[] = {
            {STR("Weapon_Handaxe_C"), "Weapon_Handaxe_C"},
            {STR("Weapon_Handaxe"), "Weapon_Handaxe"},
            {STR("/Game/Weapons/Melee/Handaxe/Weapon_Handaxe.Weapon_Handaxe_C"), "/Game/Weapons/Melee/Handaxe/Weapon_Handaxe.Weapon_Handaxe_C"},
            {STR("BlueprintGeneratedClass /Game/Weapons/Melee/Handaxe/Weapon_Handaxe.Weapon_Handaxe_C"), "BlueprintGeneratedClass /Game/Weapons/Melee/Handaxe/Weapon_Handaxe.Weapon_Handaxe_C"},
            {STR("BlueprintGeneratedClass'/Game/Weapons/Melee/Handaxe/Weapon_Handaxe.Weapon_Handaxe_C'"), "BlueprintGeneratedClass'/Game/Weapons/Melee/Handaxe/Weapon_Handaxe.Weapon_Handaxe_C'"},
            {STR("/Game/Weapons/Melee/Handaxe/Weapon_Handaxe"), "/Game/Weapons/Melee/Handaxe/Weapon_Handaxe"},
            {STR("/Game/Brickadia/Weapons/Weapon_Handaxe.Weapon_Handaxe_C"), "/Game/Brickadia/Weapons/Weapon_Handaxe.Weapon_Handaxe_C"},
            {STR("/Game/Brickadia/Gameplay/Weapons/Weapon_Handaxe.Weapon_Handaxe_C"), "/Game/Brickadia/Gameplay/Weapons/Weapon_Handaxe.Weapon_Handaxe_C"},
            {STR("/Game/Weapons/Weapon_Handaxe.Weapon_Handaxe_C"), "/Game/Weapons/Weapon_Handaxe.Weapon_Handaxe_C"},
        };
        const CandidateKind kinds[] = {
            {STR("BlueprintGeneratedClass"), "BlueprintGeneratedClass"},
            {STR("Class"), "Class"},
        };

        for (const CandidateName& name : names)
        {
            for (const CandidateKind& kind : kinds)
            {
                if (Unreal::UClass* candidate = find_treecut_handaxe_class_candidate(kind.kind, name.name))
                {
                    treecut_cache_handaxe_class_unlocked(
                        candidate,
                        std::string("FindObject(") + kind.label + "," + name.label + ")",
                        "handaxe class resolved by native object lookup");
                    return candidate;
                }
            }
        }

        treecut_cache_handaxe_class_unlocked(
            nullptr,
            "native lookup",
            "Weapon_Handaxe class could not be resolved");
        return nullptr;
    }

    bool is_treecut_context_handaxe(void* context)
    {
        Unreal::UObject* object = reinterpret_cast<Unreal::UObject*>(context);
        g_treecut_last_context.store(reinterpret_cast<uintptr_t>(context));
        g_treecut_last_context_class.store(0);

        if (!is_live_uobject(object))
        {
            std::lock_guard lock(g_treecut_mutex);
            g_treecut_last_item_type = "unknown";
            g_treecut_last_reject_reason = "context is not a live UObject";
            return false;
        }

        Unreal::UClass* object_class = nullptr;
        try
        {
            object_class = object->GetClassPrivate();
        }
        catch (...)
        {
            object_class = nullptr;
        }
        g_treecut_last_context_class.store(reinterpret_cast<uintptr_t>(object_class));

        Unreal::UClass* handaxe_class = resolve_treecut_handaxe_class();
        if (!handaxe_class)
        {
            std::lock_guard lock(g_treecut_mutex);
            g_treecut_last_item_type = "unknown";
            g_treecut_last_reject_reason = "handaxe class unresolved";
            return false;
        }

        bool matches = false;
        try
        {
            matches = object->IsA(handaxe_class);
        }
        catch (...)
        {
            matches = object_class == handaxe_class;
        }

        std::lock_guard lock(g_treecut_mutex);
        if (matches)
        {
            g_treecut_last_item_type = "handaxe";
            g_treecut_last_reject_reason.clear();
        }
        else
        {
            g_treecut_last_item_type = "non-handaxe";
            g_treecut_last_reject_reason = "weapon context did not match Weapon_Handaxe";
        }
        return matches;
    }

    bool treecut_actor_text_is_tree_like(const TreeCutTargetCandidate& candidate)
    {
        const std::string text = ascii_lower(
            candidate.name + " " +
            candidate.full_name + " " +
            candidate.class_name + " " +
            candidate.class_full_name);
        return text.find("tree") != std::string::npos;
    }

    bool treecut_object_text_may_have_console_tag(Unreal::UObject* object)
    {
        const std::string text = ascii_lower(
            object_name(object) + " " +
            object_full_name(object) + " " +
            object_class_name(object) + " " +
            object_class_full_name(object));
        return text.find("interact") != std::string::npos ||
               text.find("target") != std::string::npos ||
               text.find("component") != std::string::npos ||
               text.find("console") != std::string::npos ||
               text.find("brick") != std::string::npos ||
               text.find("tree") != std::string::npos;
    }

    bool treecut_try_actor_location(Unreal::UObject* actor, Unreal::FVector& out_vector, std::string& method)
    {
        method.clear();
        if (try_actor_k2_location(actor, out_vector))
        {
            method = "K2_GetActorLocation";
            return true;
        }
        if (try_actor_root_component_location(actor, out_vector, method))
        {
            return true;
        }
        return false;
    }

    bool treecut_try_object_location(Unreal::UObject* object, Unreal::FVector& out_vector, std::string& method)
    {
        method.clear();
        if (!is_live_uobject(object))
        {
            return false;
        }

        if (object_is_actor(object) && treecut_try_actor_location(object, out_vector, method))
        {
            return true;
        }

        if (read_transform_translation_property(object, STR("ComponentToWorld"), out_vector))
        {
            method = "ComponentToWorld";
            return true;
        }

        Unreal::UObject* outer = nullptr;
        try
        {
            outer = object->GetOuterPrivate();
        }
        catch (...)
        {
            outer = nullptr;
        }

        for (int depth = 0; depth < 4 && is_live_uobject(outer) && outer != object; ++depth)
        {
            std::string outer_method;
            if (object_is_actor(outer) && treecut_try_actor_location(outer, out_vector, outer_method))
            {
                method = "outer" + std::to_string(depth + 1) + "." + outer_method;
                return true;
            }

            if (read_transform_translation_property(outer, STR("ComponentToWorld"), out_vector))
            {
                method = "outer" + std::to_string(depth + 1) + ".ComponentToWorld";
                return true;
            }

            Unreal::UObject* next = nullptr;
            try
            {
                next = outer->GetOuterPrivate();
            }
            catch (...)
            {
                next = nullptr;
            }
            if (next == outer)
            {
                break;
            }
            outer = next;
        }

        if (read_vector_property(object, STR("RelativeLocation"), out_vector))
        {
            method = "RelativeLocation";
            return true;
        }

        return false;
    }

    bool treecut_try_direct_tree_id_console_tag(Unreal::UObject* object, TreeCutConsoleTagInfo& info)
    {
        if (!is_live_uobject(object))
        {
            return false;
        }

        const size_t before = info.tags.size();
        if (!treecut_read_console_tag_property(object, info.tags))
        {
            return false;
        }

        if (info.tags.size() <= before)
        {
            return false;
        }

        const std::string tag = treecut_first_tree_id_console_tag(info.tags);
        if (tag.empty())
        {
            return false;
        }

        treecut_note_console_tag_source(info, "target-cache.ConsoleTag", object);
        return true;
    }

    void treecut_refresh_target_cache(std::string_view reason)
    {
        const ULONGLONG refresh_started_ms = GetTickCount64();
        std::vector<TreeCutTargetCandidate> candidates;
        candidates.reserve(64);
        uint64_t scanned = 0;
        uint64_t errors = 0;
        uint64_t tagged_candidates = 0;
        bool truncated = false;

        Unreal::UObjectGlobals::ForEachUObject([&](Unreal::UObject* object, int32_t, int32_t) {
            ++scanned;
            if (candidates.size() >= kTreeCutTargetCacheMaxCandidates)
            {
                truncated = true;
                return LoopAction::Break;
            }

            if (!is_live_uobject(object))
            {
                return LoopAction::Continue;
            }

            try
            {
                TreeCutConsoleTagInfo tag_info;
                if (treecut_object_text_may_have_console_tag(object) &&
                    treecut_try_direct_tree_id_console_tag(object, tag_info))
                {
                    TreeCutTargetCandidate candidate;
                    candidate.actor = object;
                    candidate.address = object_address_hex(object);
                    candidate.name = object_name(object);
                    candidate.full_name = object_full_name(object);
                    candidate.class_name = object_class_name(object);
                    candidate.class_full_name = object_class_full_name(object);
                    candidate.console_tag = treecut_first_tree_id_console_tag(tag_info.tags);
                    candidate.console_tag_source = tag_info.source;
                    candidate.console_tag_source_object = tag_info.source_object;
                    candidate.tagged_component = !object_is_actor(object);

                    if (!candidate.console_tag.empty() &&
                        treecut_try_object_location(object, candidate.location, candidate.location_method))
                    {
                        candidates.push_back(std::move(candidate));
                        ++tagged_candidates;
                        return LoopAction::Continue;
                    }
                }

                if (!object_is_actor(object))
                {
                    return LoopAction::Continue;
                }

                TreeCutTargetCandidate candidate;
                candidate.actor = object;
                candidate.address = object_address_hex(object);
                candidate.name = object_name(object);
                candidate.full_name = object_full_name(object);
                candidate.class_name = object_class_name(object);
                candidate.class_full_name = object_class_full_name(object);

                if (!treecut_actor_text_is_tree_like(candidate))
                {
                    return LoopAction::Continue;
                }

                if (!treecut_try_actor_location(object, candidate.location, candidate.location_method))
                {
                    return LoopAction::Continue;
                }

                candidates.push_back(std::move(candidate));
            }
            catch (...)
            {
                ++errors;
            }

            return LoopAction::Continue;
        });

        g_treecut_target_cache_refreshes.fetch_add(1);
        g_treecut_target_cache_scanned_objects.store(scanned);
        g_treecut_target_cache_errors.store(errors);
        g_treecut_target_cache_last_refresh_ms.store(
            static_cast<uint64_t>(GetTickCount64() - refresh_started_ms));

        std::lock_guard lock(g_treecut_mutex);
        g_treecut_target_cache = std::move(candidates);
        g_treecut_last_target_detail =
            "cache_refresh reason=" + std::string(reason) +
            " candidates=" + std::to_string(g_treecut_target_cache.size()) +
            " tagged=" + std::to_string(tagged_candidates) +
            " scanned=" + std::to_string(scanned) +
            " errors=" + std::to_string(errors) +
            " duration_ms=" + std::to_string(g_treecut_target_cache_last_refresh_ms.load()) +
            " truncated=" + (truncated ? "true" : "false");
    }

    struct TreeCutResolvedTarget
    {
        bool found{false};
        TreeCutTargetCandidate candidate{};
        double distance_sq{0.0};
    };

    void treecut_merge_target_console_tag(TreeCutConsoleTagInfo& info, const TreeCutResolvedTarget& target)
    {
        if (!target.found || target.candidate.console_tag.empty())
        {
            return;
        }

        const size_t before = info.tags.size();
        push_console_tag_candidate(info.tags, target.candidate.console_tag, true);
        if (info.tags.size() > before && info.source.empty())
        {
            info.source = target.candidate.console_tag_source.empty()
                ? "target-cache"
                : target.candidate.console_tag_source;
            info.source_object = target.candidate.console_tag_source_object;
        }
    }

    TreeCutResolvedTarget treecut_resolve_target_actor(const double values[7])
    {
        g_treecut_target_resolve_attempts.fetch_add(1);

        std::vector<TreeCutTargetCandidate> candidates;
        {
            std::lock_guard lock(g_treecut_mutex);
            candidates = g_treecut_target_cache;
        }

        TreeCutResolvedTarget best_any;
        TreeCutResolvedTarget best_tagged;
        double best_any_distance_sq = kTreeCutTargetResolveRadiusSq;
        double best_tagged_distance_sq = kTreeCutTargetResolveRadiusSq;
        for (const TreeCutTargetCandidate& candidate : candidates)
        {
            if (!is_live_uobject(candidate.actor))
            {
                continue;
            }

            const double dx = static_cast<double>(candidate.location.X()) - values[1];
            const double dy = static_cast<double>(candidate.location.Y()) - values[2];
            const double dz = static_cast<double>(candidate.location.Z()) - values[3];
            const double distance_sq = dx * dx + dy * dy + dz * dz;
            if (!std::isfinite(distance_sq) || distance_sq > kTreeCutTargetResolveRadiusSq)
            {
                continue;
            }

            if (!candidate.console_tag.empty())
            {
                if (distance_sq <= best_tagged_distance_sq)
                {
                    best_tagged.found = true;
                    best_tagged.candidate = candidate;
                    best_tagged.distance_sq = distance_sq;
                    best_tagged_distance_sq = distance_sq;
                }
                continue;
            }

            if (distance_sq <= best_any_distance_sq)
            {
                best_any.found = true;
                best_any.candidate = candidate;
                best_any.distance_sq = distance_sq;
                best_any_distance_sq = distance_sq;
            }
        }

        TreeCutResolvedTarget best = best_tagged.found ? best_tagged : best_any;

        {
            std::lock_guard lock(g_treecut_mutex);
            if (best.found)
            {
                g_treecut_target_resolve_hits.fetch_add(1);
                g_treecut_last_target_name = best.candidate.name;
                g_treecut_last_target_full_name = best.candidate.full_name;
                g_treecut_last_target_class = best.candidate.class_name;
                g_treecut_last_target_detail =
                    "resolved distance=" + std::to_string(std::sqrt(best.distance_sq)) +
                    " tagged=" + (best.candidate.console_tag.empty() ? "false" : "true") +
                    " radius=" + std::to_string(kTreeCutTargetResolveRadius);
            }
            else
            {
                g_treecut_target_resolve_misses.fetch_add(1);
                g_treecut_last_target_name.clear();
                g_treecut_last_target_full_name.clear();
                g_treecut_last_target_class.clear();
                g_treecut_last_target_detail =
                    "miss radius=" + std::to_string(kTreeCutTargetResolveRadius) +
                    " candidates=" + std::to_string(candidates.size());
            }
        }

        return best;
    }

    void write_treecut_target_json(std::ostringstream& out, const TreeCutResolvedTarget& target)
    {
        if (!target.found)
        {
            out << ",\"targetResolved\":false";
            return;
        }

        const double distance = std::sqrt(target.distance_sq);
        out << std::setprecision(17)
            << ",\"targetResolved\":true"
            << ",\"treeActorName\":\"" << json_escape(target.candidate.name) << "\""
            << ",\"treeActorFullName\":\"" << json_escape(target.candidate.full_name) << "\""
            << ",\"treeActorPath\":\"" << json_escape(target.candidate.full_name) << "\""
            << ",\"targetActor\":{"
            << "\"id\":\"" << json_escape(!target.candidate.full_name.empty() ? target.candidate.full_name : target.candidate.address) << "\","
            << "\"address\":\"" << json_escape(target.candidate.address) << "\","
            << "\"name\":\"" << json_escape(target.candidate.name) << "\","
            << "\"fullName\":\"" << json_escape(target.candidate.full_name) << "\","
            << "\"path\":\"" << json_escape(target.candidate.full_name) << "\","
            << "\"className\":\"" << json_escape(target.candidate.class_name) << "\","
            << "\"classFullName\":\"" << json_escape(target.candidate.class_full_name) << "\","
            << "\"distance\":" << distance << ","
            << "\"location\":{\"x\":" << static_cast<double>(target.candidate.location.X())
            << ",\"y\":" << static_cast<double>(target.candidate.location.Y())
            << ",\"z\":" << static_cast<double>(target.candidate.location.Z()) << "},"
            << "\"locationMethod\":\"" << json_escape(target.candidate.location_method) << "\","
            << "\"taggedComponent\":" << (target.candidate.tagged_component ? "true" : "false") << ",";
        if (!target.candidate.console_tag.empty())
        {
            out << "\"consoleTag\":\"" << json_escape(target.candidate.console_tag) << "\","
                << "\"consoleTagSource\":\"" << json_escape(target.candidate.console_tag_source) << "\",";
        }
        out << "\"resolver\":\"cached_nearest_tree_actor\""
            << "}";
    }

    struct TreeCutProbeSlot
    {
        const char* label;
        const CharType* short_name;
        const CharType* path_a;
        const CharType* path_b;
        std::atomic<bool> installed{false};
        std::atomic<uint64_t> hits{0};
        std::atomic<uintptr_t> function{0};
        std::atomic<uintptr_t> slot{0};
        std::atomic<uintptr_t> original{0};
        std::atomic<uintptr_t> last_context{0};
        std::atomic<uintptr_t> last_stack{0};
        std::atomic<uint64_t> last_tick_ms{0};

        constexpr TreeCutProbeSlot(
            const char* label_value,
            const CharType* short_name_value,
            const CharType* path_a_value,
            const CharType* path_b_value)
            : label(label_value),
              short_name(short_name_value),
              path_a(path_a_value),
              path_b(path_b_value)
        {
        }
    };

    std::atomic<bool> g_treecut_probe_enabled{false};
    std::mutex g_treecut_probe_mutex;
    std::string g_treecut_probe_last_error;

    TreeCutProbeSlot g_treecut_probe_slots[] = {
        TreeCutProbeSlot{
            "BRWeaponStateBehavior_MeleeBase.AdvanceState",
            STR("AdvanceState"),
            STR("/Script/Brickadia.BRWeaponStateBehavior_MeleeBase:AdvanceState"),
            STR("/Script/Brickadia.BRWeaponStateBehavior_MeleeBase.AdvanceState")},
        TreeCutProbeSlot{
            "BRWeaponStateBehavior_MeleeAttack.AdvanceState",
            STR("AdvanceState"),
            STR("/Script/Brickadia.BRWeaponStateBehavior_MeleeAttack:AdvanceState"),
            STR("/Script/Brickadia.BRWeaponStateBehavior_MeleeAttack.AdvanceState")},
        TreeCutProbeSlot{
            "BRWeaponBase.MulticastReplicateAcceleratedMeleeExplosion",
            STR("MulticastReplicateAcceleratedMeleeExplosion"),
            STR("/Script/Brickadia.BRWeaponBase:MulticastReplicateAcceleratedMeleeExplosion"),
            STR("/Script/Brickadia.BRWeaponBase.MulticastReplicateAcceleratedMeleeExplosion")},
        TreeCutProbeSlot{
            "BRWeaponBase.OnWeaponFired",
            STR("OnWeaponFired"),
            STR("/Script/Brickadia.BRWeaponBase:OnWeaponFired"),
            STR("/Script/Brickadia.BRWeaponBase.OnWeaponFired")},
        TreeCutProbeSlot{
            "BRWeaponProjectile.ProcessImpactDamageableObject",
            STR("ProcessImpactDamageableObject"),
            STR("/Script/Brickadia.BRWeaponProjectile:ProcessImpactDamageableObject"),
            STR("/Script/Brickadia.BRWeaponProjectile.ProcessImpactDamageableObject")},
        TreeCutProbeSlot{
            "GameplayStatics.ApplyDamage",
            STR("ApplyDamage"),
            STR("/Script/Engine.GameplayStatics:ApplyDamage"),
            STR("/Script/Engine.GameplayStatics.ApplyDamage")},
        TreeCutProbeSlot{
            "Actor.ReceiveActorBeginOverlap",
            STR("ReceiveActorBeginOverlap"),
            STR("/Script/Engine.Actor:ReceiveActorBeginOverlap"),
            STR("/Script/Engine.Actor.ReceiveActorBeginOverlap")},
        TreeCutProbeSlot{
            "PrimitiveComponent.ReceiveComponentBeginOverlap",
            STR("ReceiveComponentBeginOverlap"),
            STR("/Script/Engine.PrimitiveComponent:ReceiveComponentBeginOverlap"),
            STR("/Script/Engine.PrimitiveComponent.ReceiveComponentBeginOverlap")},
        TreeCutProbeSlot{
            "Actor.ReceiveHit",
            STR("ReceiveHit"),
            STR("/Script/Engine.Actor:ReceiveHit"),
            STR("/Script/Engine.Actor.ReceiveHit")},
    };

    constexpr size_t kTreeCutProbeSlotCount = sizeof(g_treecut_probe_slots) / sizeof(g_treecut_probe_slots[0]);

    using TreeCutProbeDetour = void(__fastcall*)(void*, void*, void*);
    TreeCutProbeDetour g_treecut_probe_detours[kTreeCutProbeSlotCount] = {
        treecut_probe_detour_0,
        treecut_probe_detour_1,
        treecut_probe_detour_2,
        treecut_probe_detour_3,
        treecut_probe_detour_4,
        treecut_probe_detour_5,
        treecut_probe_detour_6,
        treecut_probe_detour_7,
        treecut_probe_detour_8,
    };

    std::array<std::string, kTreeCutProbeSlotCount> g_treecut_probe_last_summary;
    std::array<std::string, kTreeCutProbeSlotCount> g_treecut_probe_first_summary;
    std::array<std::atomic<uintptr_t>, kTreeCutProbeSlotCount> g_treecut_probe_last_locals;

    void treecut_probe_set_error(std::string value)
    {
        std::lock_guard lock(g_treecut_probe_mutex);
        g_treecut_probe_last_error = std::move(value);
    }

    Unreal::UObject* find_treecut_probe_function(const TreeCutProbeSlot& probe)
    {
        for (const CharType* candidate : {probe.path_a, probe.path_b})
        {
            if (!candidate)
            {
                continue;
            }
            try
            {
                if (auto* function = Unreal::UObjectGlobals::StaticFindObject(nullptr, nullptr, candidate))
                {
                    return function;
                }
            }
            catch (...)
            {
            }
        }
        if (probe.short_name)
        {
            try
            {
                if (auto* function = Unreal::UObjectGlobals::FindObject(STR("Function"), probe.short_name))
                {
                    return function;
                }
            }
            catch (...)
            {
            }
        }
        return nullptr;
    }

    bool treecut_probe_install_slot(size_t index)
    {
        if (index >= kTreeCutProbeSlotCount)
        {
            return false;
        }

        TreeCutProbeSlot& probe = g_treecut_probe_slots[index];
        if (probe.installed.load())
        {
            return true;
        }

        Unreal::UObject* function = find_treecut_probe_function(probe);
        if (!function)
        {
            return false;
        }

        const uintptr_t function_address = reinterpret_cast<uintptr_t>(function);
        const uintptr_t slot_address = function_address + kTreeCutFuncOffset;
        probe.function.store(function_address);
        probe.slot.store(slot_address);
        if (!is_accessible_memory(slot_address, sizeof(void*)))
        {
            return false;
        }

        void** slot = reinterpret_cast<void**>(slot_address);
        void* current = nullptr;
        std::memcpy(&current, slot, sizeof(current));
        if (current != reinterpret_cast<void*>(g_treecut_probe_detours[index]) &&
            (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current))))
        {
            return false;
        }

        DWORD old_protect = 0;
        if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect))
        {
            return false;
        }

        void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(g_treecut_probe_detours[index]));
        DWORD ignored = 0;
        VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
        FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

        if (previous == reinterpret_cast<void*>(g_treecut_probe_detours[index]))
        {
            previous = reinterpret_cast<void*>(probe.original.load());
        }
        if (!previous)
        {
            return false;
        }

        probe.original.store(reinterpret_cast<uintptr_t>(previous));
        probe.installed.store(true);
        return true;
    }

    size_t treecut_probe_install_all()
    {
        size_t installed = 0;
        for (size_t index = 0; index < kTreeCutProbeSlotCount; ++index)
        {
            if (treecut_probe_install_slot(index))
            {
                ++installed;
            }
        }
        if (installed == 0)
        {
            treecut_probe_set_error("no tree-cut probe candidate functions resolved");
        }
        else
        {
            treecut_probe_set_error("");
        }
        return installed;
    }

    bool should_capture_treecut_probe_summary(const TreeCutProbeSlot& probe)
    {
        return std::strstr(probe.label, "ReceiveHit") != nullptr ||
               std::strstr(probe.label, "ReceiveAnyDamage") != nullptr ||
               std::strstr(probe.label, "ApplyDamage") != nullptr ||
               std::strstr(probe.label, "ProcessImpactDamageableObject") != nullptr;
    }

    void append_probe_object(std::ostringstream& out, const char* label, Unreal::UObject* object)
    {
        if (!label || !is_live_uobject(object))
        {
            return;
        }
        out << "|" << label << "=" << compact_object_label(object);
    }

    std::string probe_param_token(std::string value)
    {
        if (value.empty())
        {
            return "unnamed";
        }
        for (char& ch : value)
        {
            const unsigned char uch = static_cast<unsigned char>(ch);
            if (!std::isalnum(uch))
            {
                ch = '_';
            }
        }
        return value;
    }

    std::string probe_property_class_label(Unreal::FProperty* property)
    {
        if (!property)
        {
            return "unknown";
        }
        try
        {
            const auto field_class = property->GetClass();
            if (field_class.IsValid())
            {
                const std::string name = narrow_string(field_class.GetName());
                if (!name.empty())
                {
                    return name;
                }
            }
        }
        catch (...)
        {
        }
        return "unknown";
    }

    void append_probe_param_metadata(std::ostringstream& out, const TreeCutProbeSlot& probe, uintptr_t locals)
    {
        auto* function = reinterpret_cast<Unreal::UFunction*>(probe.function.load());
        if (!is_live_uobject(function))
        {
            out << "|params_function_accessible=false";
            return;
        }

        int param_index = 0;
        int emitted = 0;
        try
        {
            for (Unreal::FProperty* property : Unreal::TFieldRange<Unreal::FProperty>(
                     function,
                     Unreal::EFieldIterationFlags::IncludeDeprecated))
            {
                if (!property || !property->HasAnyPropertyFlags(Unreal::EPropertyFlags::CPF_Parm))
                {
                    continue;
                }

                ++param_index;
                if (emitted >= 12)
                {
                    out << "|params_truncated=true";
                    break;
                }
                ++emitted;

                const std::string property_name = narrow_string(property->GetName());
                const std::string token = "param" + std::to_string(param_index) + "_" + probe_param_token(property_name);
                const int32_t offset = property->GetOffset_Internal();
                const uintptr_t value_address = locals + static_cast<uintptr_t>(std::max(offset, 0));

                out << "|" << token << "_offset=0x" << std::uppercase << std::hex << offset << std::dec
                    << "|" << token << "_type=" << probe_property_class_label(property);

                uint64_t raw_value = 0;
                if (read_u64_at(value_address, raw_value))
                {
                    out << "|" << token << "_raw=" << hex_u64(raw_value);
                }

                if (property_is_object_reference(property))
                {
                    append_probe_object(out, (token + "_object").c_str(), read_uobject_at(value_address));
                }
            }
        }
        catch (...)
        {
            out << "|params_error=true";
        }

        if (emitted == 0)
        {
            out << "|params=0";
        }
    }

    std::string build_treecut_probe_summary(const TreeCutProbeSlot& probe, void* context, uintptr_t locals)
    {
        std::ostringstream out;
        out << "label=" << probe.label
            << "|locals=" << pointer_hex(locals);
        append_probe_object(out, "context", reinterpret_cast<Unreal::UObject*>(context));

        if (!is_accessible_memory(locals, sizeof(uintptr_t)))
        {
            out << "|locals_accessible=false";
            return out.str();
        }

        if (std::strstr(probe.label, "ReceiveHit") != nullptr)
        {
            append_probe_object(out, "my_component", read_uobject_at(locals + 0x0));
            append_probe_object(out, "other_actor", read_uobject_at(locals + 0x8));
            append_probe_object(out, "other_component", read_uobject_at(locals + 0x10));
            append_probe_object(out, "hit_object_b0", read_uobject_at(locals + 0x68 + 0xB0));
            append_probe_object(out, "hit_object_b8", read_uobject_at(locals + 0x68 + 0xB8));
            append_probe_object(out, "hit_object_d8", read_uobject_at(locals + 0x68 + 0xD8));
        }
        else if (std::strstr(probe.label, "ReceiveAnyDamage") != nullptr)
        {
            append_probe_object(out, "damage_type_class", read_uobject_at(locals + 0x8));
            append_probe_object(out, "event_instigator", read_uobject_at(locals + 0x10));
            append_probe_object(out, "damage_causer", read_uobject_at(locals + 0x18));
        }
        else if (std::strstr(probe.label, "ApplyDamage") != nullptr)
        {
            append_probe_param_metadata(out, probe, locals);
            append_probe_object(out, "damaged_actor", read_uobject_at(locals + 0x0));
            append_probe_object(out, "event_instigator", read_uobject_at(locals + 0x10));
            append_probe_object(out, "damage_causer", read_uobject_at(locals + 0x18));
            append_probe_object(out, "damage_type_class", read_uobject_at(locals + 0x20));
        }
        else if (std::strstr(probe.label, "ProcessImpactDamageableObject") != nullptr)
        {
            append_probe_object(out, "hit_object_b0", read_uobject_at(locals + 0xB0));
            append_probe_object(out, "hit_object_b8", read_uobject_at(locals + 0xB8));
            append_probe_object(out, "hit_object_d8", read_uobject_at(locals + 0xD8));
        }

        return out.str();
    }

    void treecut_probe_handle(size_t index, void* context, void* stack, void* result)
    {
        NativeFunc original = nullptr;
        if (index < kTreeCutProbeSlotCount)
        {
            TreeCutProbeSlot& probe = g_treecut_probe_slots[index];
            if (g_treecut_probe_enabled.load())
            {
                probe.hits.fetch_add(1);
                probe.last_context.store(reinterpret_cast<uintptr_t>(context));
                probe.last_stack.store(reinterpret_cast<uintptr_t>(stack));
                probe.last_tick_ms.store(GetTickCount64());

                uintptr_t locals = 0;
                if (read_process_event_locals(stack, locals))
                {
                    g_treecut_probe_last_locals[index].store(locals);
                    if (should_capture_treecut_probe_summary(probe))
                    {
                        const std::string summary = build_treecut_probe_summary(probe, context, locals);
                        std::lock_guard lock(g_treecut_probe_mutex);
                        if (g_treecut_probe_first_summary[index].empty())
                        {
                            g_treecut_probe_first_summary[index] = summary;
                        }
                        g_treecut_probe_last_summary[index] = summary;
                    }
                }
            }
            original = reinterpret_cast<NativeFunc>(probe.original.load());
        }
        if (original && original != reinterpret_cast<NativeFunc>(g_treecut_probe_detours[index]))
        {
            original(context, stack, result);
        }
    }

    void __fastcall treecut_probe_detour_0(void* context, void* stack, void* result)
    {
        treecut_probe_handle(0, context, stack, result);
    }

    void __fastcall treecut_probe_detour_1(void* context, void* stack, void* result)
    {
        treecut_probe_handle(1, context, stack, result);
    }

    void __fastcall treecut_probe_detour_2(void* context, void* stack, void* result)
    {
        treecut_probe_handle(2, context, stack, result);
    }

    void __fastcall treecut_probe_detour_3(void* context, void* stack, void* result)
    {
        treecut_probe_handle(3, context, stack, result);
    }

    void __fastcall treecut_probe_detour_4(void* context, void* stack, void* result)
    {
        treecut_probe_handle(4, context, stack, result);
    }

    void __fastcall treecut_probe_detour_5(void* context, void* stack, void* result)
    {
        treecut_probe_handle(5, context, stack, result);
    }

    void __fastcall treecut_probe_detour_6(void* context, void* stack, void* result)
    {
        treecut_probe_handle(6, context, stack, result);
    }

    void __fastcall treecut_probe_detour_7(void* context, void* stack, void* result)
    {
        treecut_probe_handle(7, context, stack, result);
    }

    void __fastcall treecut_probe_detour_8(void* context, void* stack, void* result)
    {
        treecut_probe_handle(8, context, stack, result);
    }

    std::string treecut_probe_status_text()
    {
        std::lock_guard lock(g_treecut_probe_mutex);
        uint64_t total_hits = 0;
        size_t installed = 0;
        for (size_t index = 0; index < kTreeCutProbeSlotCount; ++index)
        {
            total_hits += g_treecut_probe_slots[index].hits.load();
            if (g_treecut_probe_slots[index].installed.load())
            {
                ++installed;
            }
        }

        std::ostringstream out;
        out << "Tree-cut probe status\n"
            << "source=BMFSocketTreeCutProbe\n"
            << "enabled=" << (g_treecut_probe_enabled.load() ? "true" : "false") << "\n"
            << "installed=" << installed << "\n"
            << "candidates=" << kTreeCutProbeSlotCount << "\n"
            << "total_hits=" << total_hits << "\n"
            << "last_error=" << json_escape(g_treecut_probe_last_error) << "\n";

        for (size_t index = 0; index < kTreeCutProbeSlotCount; ++index)
        {
            const TreeCutProbeSlot& probe = g_treecut_probe_slots[index];
            out << "probe." << index << ".label=" << json_escape(probe.label) << "\n"
                << "probe." << index << ".installed=" << (probe.installed.load() ? "true" : "false") << "\n"
                << "probe." << index << ".hits=" << probe.hits.load() << "\n"
                << "probe." << index << ".function=" << json_escape(pointer_hex(probe.function.load())) << "\n"
                << "probe." << index << ".slot=" << json_escape(pointer_hex(probe.slot.load())) << "\n"
                << "probe." << index << ".original=" << json_escape(pointer_hex(probe.original.load())) << "\n"
                << "probe." << index << ".last_context=" << json_escape(pointer_hex(probe.last_context.load())) << "\n"
                << "probe." << index << ".last_stack=" << json_escape(pointer_hex(probe.last_stack.load())) << "\n"
                << "probe." << index << ".last_locals=" << json_escape(pointer_hex(g_treecut_probe_last_locals[index].load())) << "\n"
                << "probe." << index << ".last_tick_ms=" << probe.last_tick_ms.load() << "\n"
                << "probe." << index << ".first_summary=" << json_escape(g_treecut_probe_first_summary[index]) << "\n"
                << "probe." << index << ".last_summary=" << json_escape(g_treecut_probe_last_summary[index]) << "\n";
        }
        return out.str();
    }

    std::string compact_tag_list(const std::vector<std::string>& tags)
    {
        std::ostringstream out;
        for (size_t index = 0; index < tags.size(); ++index)
        {
            if (index > 0)
            {
                out << ",";
            }
            out << tags[index];
        }
        return out.str();
    }

    bool treecut_tags_include_exact(const std::vector<std::string>& tags, const std::string& wanted)
    {
        for (const std::string& tag : tags)
        {
            if (ascii_lower(trim_ascii(tag)) == wanted)
            {
                return true;
            }
        }
        return false;
    }

    std::string object_outer_chain(Unreal::UObject* object, int max_depth)
    {
        std::ostringstream out;
        Unreal::UObject* current = object;
        for (int depth = 0; depth < max_depth && is_live_uobject(current); ++depth)
        {
            if (depth > 0)
            {
                out << " > ";
            }
            out << depth << ":" << compact_object_label(current);

            Unreal::UObject* next = nullptr;
            try
            {
                next = current->GetOuterPrivate();
            }
            catch (...)
            {
                next = nullptr;
            }
            if (!is_live_uobject(next) || next == current)
            {
                break;
            }
            current = next;
        }
        return out.str();
    }

    std::string treecut_find_console_tag_text(std::string_view raw_tag, size_t max_results, uint64_t max_scan)
    {
        const std::string wanted = ascii_lower(trim_ascii(raw_tag));
        std::ostringstream out;
        out << "Tree-cut console tag lookup\n"
            << "source=BMFSocketTreeCutFindTag\n"
            << "ok=" << (!wanted.empty() ? "true" : "false") << "\n"
            << "tag=" << json_escape(wanted) << "\n"
            << "max_results=" << max_results << "\n"
            << "max_scan=" << max_scan << "\n";

        if (wanted.empty())
        {
            out << "code=TREE_CUT_FIND_TAG_REQUIRED\n"
                << "detail=tag is required\n";
            return out.str();
        }

        out << "code=TREE_CUT_FIND_TAG_DISABLED\n"
            << "detail=disabled because broad UObject ConsoleTag scans held the game thread and triggered Brickadia hang detection\n"
            << "matches=0\n"
            << "scanned=0\n"
            << "inspected=0\n"
            << "errors=0\n"
            << "truncated=false\n"
            << "duration_ms=0\n";
        return out.str();
    }

    constexpr uintptr_t kBrickLookupOffset = 0x430E8C0;
    constexpr uintptr_t kBrickRegistryOffset = 0x788B098;
    constexpr uintptr_t kBrickArrayBaseOffset = 0x788AFE0;
    constexpr uintptr_t kBrickSetVisibilityOffset = 0x4355210;
    constexpr uintptr_t kBrickSetCollisionChannelsOffset = 0x43548C0;
    constexpr uintptr_t kBrickPlaceActionMethodBlockOffset = 0x6C77CE0;
    constexpr uintptr_t kBrickVisibilityActionMethodBlockOffset = 0x6C78230;
    constexpr uintptr_t kBrickCollisionActionMethodBlockOffset = 0x6C78450;
    constexpr uintptr_t kBrickActionApplySlotOffset = 0x18;
    constexpr size_t kBrickRuntimeStride = 0x78;
    constexpr uintptr_t kBrickOwnerOffset = 0x08;
    constexpr uintptr_t kBrickCollisionChannelsOffset = 0x49;
    constexpr uintptr_t kBrickVisibleOffset = 0x4B;
    constexpr uintptr_t kBrickStateFlagsOffset = 0x76;
    constexpr uint8_t kBrickDefaultCollisionChannels = 0x8F;

    using BrickLookupFn = uintptr_t(__fastcall*)(uintptr_t, uint32_t);
    using BrickSetVisibilityFn = void(__fastcall*)(uintptr_t, uintptr_t, uint8_t);
    using BrickSetCollisionChannelsFn = void(__fastcall*)(uintptr_t, uintptr_t, uint8_t);
    using BrickActionApplyFn = void(__fastcall*)(void*, void*, void*, void*, void*, void*);
    using BrickLowSetterFn = void(__fastcall*)(uintptr_t, uintptr_t, uint8_t);

    struct InlineDetour
    {
        std::atomic<bool> installed{false};
        std::atomic<uintptr_t> target{0};
        std::atomic<uintptr_t> trampoline{0};
        size_t overwrite_length{0};
    };

    struct BrickPhysicalOriginal
    {
        bool captured{false};
        uint8_t visible{1};
        uint8_t collision_channels{kBrickDefaultCollisionChannels};
    };

    std::mutex g_brick_physical_mutex;
    std::unordered_map<uint32_t, BrickPhysicalOriginal> g_brick_physical_originals;
    std::atomic<uintptr_t> g_brick_grid_context_cached{0};
    std::string g_brick_grid_context_cached_source;
    std::string g_brick_runtime_context_hook_error;
    std::atomic<bool> g_brick_runtime_context_hooks_installed{false};
    std::atomic<uintptr_t> g_brick_place_action_apply_slot{0};
    std::atomic<uintptr_t> g_brick_visibility_action_apply_slot{0};
    std::atomic<uintptr_t> g_brick_collision_action_apply_slot{0};
    std::atomic<uintptr_t> g_brick_place_action_apply_original{0};
    std::atomic<uintptr_t> g_brick_visibility_action_apply_original{0};
    std::atomic<uintptr_t> g_brick_collision_action_apply_original{0};
    InlineDetour g_brick_visibility_low_setter_hook;
    InlineDetour g_brick_collision_low_setter_hook;
    std::atomic<uint64_t> g_brick_place_action_apply_hits{0};
    std::atomic<uint64_t> g_brick_visibility_action_apply_hits{0};
    std::atomic<uint64_t> g_brick_collision_action_apply_hits{0};
    std::atomic<uint64_t> g_brick_visibility_low_setter_hits{0};
    std::atomic<uint64_t> g_brick_collision_low_setter_hits{0};
    std::atomic<uint64_t> g_brick_context_capture_hits{0};
    std::atomic<uint64_t> g_brick_context_capture_rejects{0};
    std::atomic<bool> g_brick_grid_context_background_scan_running{false};
    std::atomic<uint64_t> g_brick_grid_context_background_scan_requests{0};
    std::atomic<uint64_t> g_brick_grid_context_background_scan_completions{0};
    std::atomic<uint64_t> g_brick_grid_context_background_scan_failures{0};
    std::atomic<uint64_t> g_brick_grid_context_background_scan_duration_ms{0};
    std::atomic<uintptr_t> g_brick_grid_context_background_scan_address{0};
    std::atomic<uint32_t> g_brick_grid_context_background_scan_cell_index{0};
    std::atomic<uint32_t> g_brick_grid_context_background_scan_sub_index{0};
    std::string g_brick_grid_context_background_scan_detail;

    bool brick_grid_context_record_for_brick(uintptr_t brick_address,
                                             uintptr_t raw_context,
                                             const char* source);

    bool brick_physical_set_enabled()
    {
        return env_flag_enabled("BMF_BRICK_RUNTIME_SET_ENABLED") ||
               env_flag_enabled("BMF_TREE_PHYSICAL_SET_ENABLED");
    }

    uintptr_t brickadia_module_base()
    {
        return reinterpret_cast<uintptr_t>(GetModuleHandleW(nullptr));
    }

    bool brick_runtime_context_hooks_enabled()
    {
        return env_flag_enabled("BMF_BRICK_RUNTIME_CONTEXT_HOOK_ENABLED") ||
               env_flag_enabled("BMF_BRICK_CONTEXT_HOOK_ENABLED");
    }

    bool brick_runtime_place_context_hook_enabled()
    {
        return env_flag_enabled("BMF_BRICK_RUNTIME_PLACE_CONTEXT_HOOK_ENABLED") ||
               env_flag_enabled("BMF_BRICK_PLACE_CONTEXT_HOOK_ENABLED");
    }

    bool brick_runtime_low_setter_context_hook_enabled()
    {
        return env_flag_enabled("BMF_BRICK_RUNTIME_LOW_SETTER_HOOK_ENABLED") ||
               env_flag_enabled("BMF_BRICK_LOW_SETTER_HOOK_ENABLED");
    }

    void brick_runtime_context_set_error(std::string value)
    {
        std::lock_guard lock(g_brick_physical_mutex);
        g_brick_runtime_context_hook_error = std::move(value);
    }

    bool brick_grid_context_record(void* raw_context, const char* source)
    {
        const uintptr_t address = reinterpret_cast<uintptr_t>(raw_context);
        if (address == 0 || !is_accessible_memory(address, 0x2E8))
        {
            g_brick_context_capture_rejects.fetch_add(1);
            return false;
        }

        g_brick_grid_context_cached.store(address);
        g_brick_context_capture_hits.fetch_add(1);
        {
            std::lock_guard lock(g_brick_physical_mutex);
            g_brick_grid_context_cached_source = source ? source : "unknown";
            g_brick_runtime_context_hook_error.clear();
        }
        return true;
    }

    void __fastcall brick_place_action_apply_detour(
        void* action,
        void* grid_context,
        void* context,
        void* target,
        void* errors,
        void* permissions)
    {
        g_brick_place_action_apply_hits.fetch_add(1);
        brick_grid_context_record(grid_context, "place-brick-action-apply");

        auto original = reinterpret_cast<BrickActionApplyFn>(
            g_brick_place_action_apply_original.load());
        if (original && original != &brick_place_action_apply_detour)
        {
            original(action, grid_context, context, target, errors, permissions);
        }
    }

    void __fastcall brick_visibility_action_apply_detour(
        void* action,
        void* grid_context,
        void* context,
        void* target,
        void* errors,
        void* permissions)
    {
        g_brick_visibility_action_apply_hits.fetch_add(1);
        brick_grid_context_record(grid_context, "visibility-action-apply");

        auto original = reinterpret_cast<BrickActionApplyFn>(
            g_brick_visibility_action_apply_original.load());
        if (original && original != &brick_visibility_action_apply_detour)
        {
            original(action, grid_context, context, target, errors, permissions);
        }
    }

    void __fastcall brick_collision_action_apply_detour(
        void* action,
        void* grid_context,
        void* context,
        void* target,
        void* errors,
        void* permissions)
    {
        g_brick_collision_action_apply_hits.fetch_add(1);
        brick_grid_context_record(grid_context, "collision-action-apply");

        auto original = reinterpret_cast<BrickActionApplyFn>(
            g_brick_collision_action_apply_original.load());
        if (original && original != &brick_collision_action_apply_detour)
        {
            original(action, grid_context, context, target, errors, permissions);
        }
    }

    void __fastcall brick_visibility_low_setter_detour(
        uintptr_t brick_address,
        uintptr_t grid_context,
        uint8_t visible)
    {
        g_brick_visibility_low_setter_hits.fetch_add(1);
        brick_grid_context_record_for_brick(
            brick_address,
            grid_context,
            "visibility-low-setter");

        auto original = reinterpret_cast<BrickLowSetterFn>(
            g_brick_visibility_low_setter_hook.trampoline.load());
        if (original && original != &brick_visibility_low_setter_detour)
        {
            original(brick_address, grid_context, visible);
        }
    }

    void __fastcall brick_collision_low_setter_detour(
        uintptr_t brick_address,
        uintptr_t grid_context,
        uint8_t collision_channels)
    {
        g_brick_collision_low_setter_hits.fetch_add(1);
        brick_grid_context_record_for_brick(
            brick_address,
            grid_context,
            "collision-low-setter");

        auto original = reinterpret_cast<BrickLowSetterFn>(
            g_brick_collision_low_setter_hook.trampoline.load());
        if (original && original != &brick_collision_low_setter_detour)
        {
            original(brick_address, grid_context, collision_channels);
        }
    }

    bool brick_runtime_context_hook_slot(
        uintptr_t module_base,
        uintptr_t method_block_offset,
        const char* name,
        void* detour,
        std::atomic<uintptr_t>& slot_store,
        std::atomic<uintptr_t>& original_store)
    {
        const uintptr_t method_block = module_base + method_block_offset;
        const uintptr_t slot_address = method_block + kBrickActionApplySlotOffset;
        if (!is_accessible_memory(slot_address, sizeof(void*)))
        {
            brick_runtime_context_set_error(
                std::string(name) + " action apply slot is not accessible");
            return false;
        }

        void** slot = reinterpret_cast<void**>(slot_address);
        void* current = nullptr;
        std::memcpy(&current, slot, sizeof(current));
        if (current == detour)
        {
            slot_store.store(slot_address);
            return true;
        }
        if (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current)))
        {
            brick_runtime_context_set_error(
                std::string(name) + " action apply original is not executable");
            return false;
        }

        DWORD old_protect = 0;
        if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect))
        {
            brick_runtime_context_set_error(
                std::string(name) + " action apply VirtualProtect failed: " +
                std::to_string(GetLastError()));
            return false;
        }

        void* previous = InterlockedExchangePointer(slot, detour);
        DWORD ignored = 0;
        VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
        FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

        if (previous == detour)
        {
            previous = reinterpret_cast<void*>(original_store.load());
        }
        if (!previous)
        {
            brick_runtime_context_set_error(
                std::string(name) + " action apply slot had no original");
            return false;
        }

        slot_store.store(slot_address);
        original_store.store(reinterpret_cast<uintptr_t>(previous));
        return true;
    }

    void write_absolute_jump(uint8_t* destination, uintptr_t target, size_t length)
    {
        std::memset(destination, 0x90, length);
        destination[0] = 0xFF;
        destination[1] = 0x25;
        destination[2] = 0x00;
        destination[3] = 0x00;
        destination[4] = 0x00;
        destination[5] = 0x00;
        std::memcpy(destination + 6, &target, sizeof(target));
    }

    bool install_inline_detour(uintptr_t target,
                               void* detour,
                               size_t overwrite_length,
                               const char* name,
                               InlineDetour& state)
    {
        constexpr size_t kAbsoluteJumpLength = 14;
        if (state.installed.load())
        {
            return true;
        }
        if (overwrite_length < kAbsoluteJumpLength)
        {
            brick_runtime_context_set_error(
                std::string(name) + " inline detour overwrite length is too short");
            return false;
        }
        if (!is_executable_memory(target) ||
            !is_accessible_memory(target, overwrite_length))
        {
            brick_runtime_context_set_error(
                std::string(name) + " inline detour target is not executable/readable");
            return false;
        }

        const size_t trampoline_size = overwrite_length + kAbsoluteJumpLength;
        auto* trampoline = static_cast<uint8_t*>(
            VirtualAlloc(
                nullptr,
                trampoline_size,
                MEM_RESERVE | MEM_COMMIT,
                PAGE_EXECUTE_READWRITE));
        if (!trampoline)
        {
            brick_runtime_context_set_error(
                std::string(name) + " inline detour trampoline allocation failed: " +
                std::to_string(GetLastError()));
            return false;
        }

        std::memcpy(trampoline, reinterpret_cast<void*>(target), overwrite_length);
        write_absolute_jump(
            trampoline + overwrite_length,
            target + overwrite_length,
            kAbsoluteJumpLength);
        FlushInstructionCache(GetCurrentProcess(), trampoline, trampoline_size);

        DWORD old_protect = 0;
        if (!VirtualProtect(
                reinterpret_cast<void*>(target),
                overwrite_length,
                PAGE_EXECUTE_READWRITE,
                &old_protect))
        {
            VirtualFree(trampoline, 0, MEM_RELEASE);
            brick_runtime_context_set_error(
                std::string(name) + " inline detour VirtualProtect failed: " +
                std::to_string(GetLastError()));
            return false;
        }

        write_absolute_jump(
            reinterpret_cast<uint8_t*>(target),
            reinterpret_cast<uintptr_t>(detour),
            overwrite_length);
        DWORD ignored = 0;
        VirtualProtect(
            reinterpret_cast<void*>(target),
            overwrite_length,
            old_protect,
            &ignored);
        FlushInstructionCache(
            GetCurrentProcess(),
            reinterpret_cast<void*>(target),
            overwrite_length);

        state.target.store(target);
        state.trampoline.store(reinterpret_cast<uintptr_t>(trampoline));
        state.overwrite_length = overwrite_length;
        state.installed.store(true);
        return true;
    }

    bool brick_low_setter_context_hook_install(uintptr_t module_base)
    {
        if (!brick_runtime_low_setter_context_hook_enabled())
        {
            return false;
        }

        const uintptr_t visibility_target = module_base + kBrickSetVisibilityOffset + 0x20;
        const uintptr_t collision_target = module_base + kBrickSetCollisionChannelsOffset + 0x20;
        const bool visibility_ok = install_inline_detour(
            visibility_target,
            reinterpret_cast<void*>(&brick_visibility_low_setter_detour),
            16,
            "visibility low-setter",
            g_brick_visibility_low_setter_hook);
        const bool collision_ok = install_inline_detour(
            collision_target,
            reinterpret_cast<void*>(&brick_collision_low_setter_detour),
            14,
            "collision low-setter",
            g_brick_collision_low_setter_hook);
        return visibility_ok || collision_ok;
    }

    bool brick_runtime_context_hook_install()
    {
        if (!brick_runtime_context_hooks_enabled() &&
            !brick_runtime_low_setter_context_hook_enabled())
        {
            return false;
        }
        if (g_brick_runtime_context_hooks_installed.load())
        {
            return true;
        }

        const uintptr_t module_base = brickadia_module_base();
        if (module_base == 0)
        {
            brick_runtime_context_set_error("Brickadia module base unavailable");
            return false;
        }

        bool place_ok = false;
        if (brick_runtime_context_hooks_enabled() &&
            brick_runtime_place_context_hook_enabled())
        {
            place_ok = brick_runtime_context_hook_slot(
                module_base,
                kBrickPlaceActionMethodBlockOffset,
                "place-brick",
                reinterpret_cast<void*>(&brick_place_action_apply_detour),
                g_brick_place_action_apply_slot,
                g_brick_place_action_apply_original);
        }
        bool visibility_ok = false;
        bool collision_ok = false;
        if (brick_runtime_context_hooks_enabled())
        {
            visibility_ok = brick_runtime_context_hook_slot(
                module_base,
                kBrickVisibilityActionMethodBlockOffset,
                "visibility",
                reinterpret_cast<void*>(&brick_visibility_action_apply_detour),
                g_brick_visibility_action_apply_slot,
                g_brick_visibility_action_apply_original);
            collision_ok = brick_runtime_context_hook_slot(
                module_base,
                kBrickCollisionActionMethodBlockOffset,
                "collision",
                reinterpret_cast<void*>(&brick_collision_action_apply_detour),
                g_brick_collision_action_apply_slot,
                g_brick_collision_action_apply_original);
        }
        const bool low_setter_ok = brick_low_setter_context_hook_install(module_base);

        const bool installed = place_ok || visibility_ok || collision_ok || low_setter_ok;
        g_brick_runtime_context_hooks_installed.store(installed);
        if (installed)
        {
            brick_runtime_context_set_error("");
        }
        return installed;
    }

    bool brick_physical_lookup(uint32_t brick_id,
                              uintptr_t& out_module_base,
                              uintptr_t& out_registry_address,
                              uintptr_t& out_brick_address,
                              std::string& out_code,
                              std::string& out_detail)
    {
        out_module_base = brickadia_module_base();
        out_registry_address = 0;
        out_brick_address = 0;
        if (out_module_base == 0)
        {
            out_code = "BRICK_MODULE_UNAVAILABLE";
            out_detail = "GetModuleHandleW(nullptr) returned no module base";
            return false;
        }

        const uintptr_t lookup_address = out_module_base + kBrickLookupOffset;
        out_registry_address = out_module_base + kBrickRegistryOffset;
        if (!is_executable_memory(lookup_address))
        {
            out_code = "BRICK_LOOKUP_UNAVAILABLE";
            out_detail = "brick lookup function address is not executable";
            return false;
        }
        if (!is_accessible_memory(out_registry_address, sizeof(uintptr_t)))
        {
            out_code = "BRICK_REGISTRY_UNAVAILABLE";
            out_detail = "brick registry global is not accessible";
            return false;
        }

        auto lookup = reinterpret_cast<BrickLookupFn>(lookup_address);
        uintptr_t brick_address = 0;
        __try
        {
            brick_address = lookup(out_registry_address, brick_id);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            out_code = "BRICK_LOOKUP_EXCEPTION";
            out_detail = "brick lookup raised a structured exception";
            return false;
        }

        if (brick_address == 0)
        {
            out_code = "BRICK_NOT_FOUND";
            out_detail = "brick lookup returned null";
            return false;
        }
        if (!is_accessible_memory(brick_address, kBrickRuntimeStride))
        {
            out_code = "BRICK_MEMORY_UNAVAILABLE";
            out_detail = "brick memory is not accessible";
            return false;
        }

        out_brick_address = brick_address;
        out_code = "OK";
        out_detail = "";
        return true;
    }

    bool read_sparse_bit(uintptr_t inline_bits_address,
                         uintptr_t heap_bits_address,
                         uint32_t index,
                         bool& out_active,
                         uintptr_t& out_bits_address)
    {
        out_active = false;
        out_bits_address = heap_bits_address != 0 ? heap_bits_address : inline_bits_address;
        const uintptr_t word_address = out_bits_address + static_cast<uintptr_t>(index >> 5) * sizeof(uint32_t);
        uint32_t word = 0;
        if (out_bits_address == 0 || !read_u32_at(word_address, word))
        {
            return false;
        }
        out_active = ((word >> (index & 0x1F)) & 1U) != 0;
        return true;
    }

    bool safe_offset(uintptr_t base, uintptr_t offset, uintptr_t& out_address)
    {
        if (base > UINTPTR_MAX - offset)
        {
            out_address = 0;
            return false;
        }
        out_address = base + offset;
        return true;
    }

    bool brick_grid_context_is_plausible(uintptr_t address,
                                         uint32_t brick_cell_index,
                                         uint32_t brick_sub_index)
    {
        if (address == 0 || !is_accessible_memory(address, 0x2E8))
        {
            return false;
        }

        uint64_t group_array = 0;
        uint64_t group_bits_heap = 0;
        uint64_t cell_array = 0;
        uint64_t cell_bits_heap = 0;
        int32_t group_count = -1;
        int32_t group_active_limit = -1;
        int32_t cell_count = -1;
        int32_t cell_active_limit = -1;
        if (!read_u64_at(address + 0x210, group_array) ||
            !read_i32_at(address + 0x218, group_count) ||
            !read_u64_at(address + 0x230, group_bits_heap) ||
            !read_i32_at(address + 0x238, group_active_limit) ||
            !read_u64_at(address + 0x2B8, cell_array) ||
            !read_i32_at(address + 0x2C0, cell_count) ||
            !read_u64_at(address + 0x2D8, cell_bits_heap) ||
            !read_i32_at(address + 0x2E0, cell_active_limit))
        {
            return false;
        }

        if (cell_count <= 0 ||
            cell_active_limit <= 0 ||
            group_count <= 0 ||
            group_active_limit <= 0 ||
            brick_cell_index >= static_cast<uint32_t>(cell_count) ||
            brick_cell_index >= static_cast<uint32_t>(cell_active_limit))
        {
            return false;
        }

        bool cell_active = false;
        uintptr_t cell_bits_address = 0;
        if (!read_sparse_bit(
                address + 0x2C8,
                static_cast<uintptr_t>(cell_bits_heap),
                brick_cell_index,
                cell_active,
                cell_bits_address) ||
            !cell_active)
        {
            return false;
        }

        uintptr_t cell_entry_address = 0;
        const uintptr_t cell_entry_offset = static_cast<uintptr_t>(brick_cell_index) * 0x28;
        if (!safe_offset(static_cast<uintptr_t>(cell_array), cell_entry_offset, cell_entry_address) ||
            !is_accessible_memory(cell_entry_address, 0x28))
        {
            return false;
        }

        uint32_t group_index = UINT32_MAX;
        int32_t cell_sub_limit = -1;
        if (!read_u32_at(cell_entry_address, group_index) ||
            !read_i32_at(cell_entry_address + 0x20, cell_sub_limit))
        {
            return false;
        }
        if (cell_sub_limit <= 0 ||
            brick_sub_index >= static_cast<uint32_t>(cell_sub_limit) ||
            group_index >= static_cast<uint32_t>(group_count) ||
            group_index >= static_cast<uint32_t>(group_active_limit))
        {
            return false;
        }

        bool group_active = false;
        uintptr_t group_bits_address = 0;
        if (!read_sparse_bit(
                address + 0x220,
                static_cast<uintptr_t>(group_bits_heap),
                group_index,
                group_active,
                group_bits_address) ||
            !group_active)
        {
            return false;
        }

        uintptr_t group_entry_address = 0;
        const uintptr_t group_entry_offset = static_cast<uintptr_t>(group_index) * 0x370;
        return safe_offset(static_cast<uintptr_t>(group_array), group_entry_offset, group_entry_address) &&
               is_accessible_memory(group_entry_address, 0x370);
    }

    bool brick_grid_context_record_for_brick(uintptr_t brick_address,
                                             uintptr_t raw_context,
                                             const char* source)
    {
        if (brick_address == 0 || raw_context == 0 ||
            !is_accessible_memory(brick_address, kBrickRuntimeStride))
        {
            g_brick_context_capture_rejects.fetch_add(1);
            return false;
        }

        uint32_t brick_cell_index = 0;
        uint32_t brick_sub_index = 0;
        if (!read_u32_at(brick_address, brick_cell_index) ||
            !read_u32_at(brick_address + 0x04, brick_sub_index) ||
            !brick_grid_context_is_plausible(raw_context, brick_cell_index, brick_sub_index))
        {
            g_brick_context_capture_rejects.fetch_add(1);
            return false;
        }

        g_brick_grid_context_cached.store(raw_context);
        g_brick_context_capture_hits.fetch_add(1);
        {
            std::lock_guard lock(g_brick_physical_mutex);
            g_brick_grid_context_cached_source = source ? source : "unknown";
            g_brick_runtime_context_hook_error.clear();
        }
        return true;
    }

    struct BrickGridContextScanResult
    {
        bool enabled{false};
        bool found{false};
        uintptr_t address{0};
        uint64_t regions{0};
        uint64_t scanned_bytes{0};
        uint64_t probes{0};
        uint64_t plausible_checks{0};
        uint64_t duration_ms{0};
        std::string detail;
    };

    struct BrickOwnerContextScanResult
    {
        bool enabled{false};
        bool found{false};
        uintptr_t address{0};
        uint64_t direct_candidates{0};
        uint64_t pointer_candidates{0};
        uint64_t nested_pointer_candidates{0};
        uint64_t plausible_checks{0};
        uint64_t duration_ms{0};
        std::string source;
        std::string detail;
    };

    bool memory_region_readable(const MEMORY_BASIC_INFORMATION& mbi)
    {
        if (mbi.State != MEM_COMMIT || (mbi.Protect & PAGE_GUARD) || (mbi.Protect & PAGE_NOACCESS))
        {
            return false;
        }
        const DWORD readable_flags =
            PAGE_READONLY |
            PAGE_READWRITE |
            PAGE_WRITECOPY |
            PAGE_EXECUTE_READ |
            PAGE_EXECUTE_READWRITE |
            PAGE_EXECUTE_WRITECOPY;
        return (mbi.Protect & readable_flags) != 0;
    }

    bool read_scan_candidate_fields(uintptr_t address,
                                    int32_t& group_count,
                                    int32_t& group_active_limit,
                                    uint64_t& cell_array,
                                    int32_t& cell_count,
                                    int32_t& cell_active_limit)
    {
        __try
        {
            std::memcpy(&group_count, reinterpret_cast<void*>(address + 0x218), sizeof(group_count));
            std::memcpy(&group_active_limit, reinterpret_cast<void*>(address + 0x238), sizeof(group_active_limit));
            std::memcpy(&cell_array, reinterpret_cast<void*>(address + 0x2B8), sizeof(cell_array));
            std::memcpy(&cell_count, reinterpret_cast<void*>(address + 0x2C0), sizeof(cell_count));
            std::memcpy(&cell_active_limit, reinterpret_cast<void*>(address + 0x2E0), sizeof(cell_active_limit));
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    BrickGridContextScanResult brick_grid_context_scan_memory(uint32_t brick_cell_index,
                                                              uint32_t brick_sub_index)
    {
        BrickGridContextScanResult result{};
        result.enabled = true;

        const auto started = std::chrono::steady_clock::now();
        uintptr_t cursor = 0x10000;
        constexpr uint64_t kMaxScannedBytes = 2048ULL * 1024ULL * 1024ULL;
        constexpr uint64_t kMaxRegions = 32768;
        constexpr uintptr_t kScanAlignment = 0x8;
        constexpr int32_t kMaxSparseCount = 500000;

        while (cursor < UINTPTR_MAX && result.regions < kMaxRegions && result.scanned_bytes < kMaxScannedBytes)
        {
            MEMORY_BASIC_INFORMATION mbi{};
            if (VirtualQuery(reinterpret_cast<void*>(cursor), &mbi, sizeof(mbi)) == 0)
            {
                break;
            }

            const uintptr_t region_start = reinterpret_cast<uintptr_t>(mbi.BaseAddress);
            const uintptr_t region_end = region_start + mbi.RegionSize;
            cursor = region_end > cursor ? region_end : cursor + 0x1000;
            if (!memory_region_readable(mbi) || mbi.Type != MEM_PRIVATE || mbi.RegionSize < 0x2E8)
            {
                continue;
            }

            result.regions++;
            uintptr_t scan_start = (region_start + (kScanAlignment - 1)) & ~(kScanAlignment - 1);
            const uintptr_t scan_end = region_end > 0x2E8 ? region_end - 0x2E8 : region_start;
            for (uintptr_t address = scan_start;
                 address <= scan_end && result.scanned_bytes < kMaxScannedBytes;
                 address += kScanAlignment)
            {
                result.probes++;
                result.scanned_bytes += kScanAlignment;

                int32_t group_count = -1;
                int32_t group_active_limit = -1;
                uint64_t cell_array = 0;
                int32_t cell_count = -1;
                int32_t cell_active_limit = -1;
                if (!read_scan_candidate_fields(
                        address,
                        group_count,
                        group_active_limit,
                        cell_array,
                        cell_count,
                        cell_active_limit))
                {
                    continue;
                }

                if (group_count <= 0 ||
                    group_active_limit <= 0 ||
                    cell_count <= 0 ||
                    cell_active_limit <= 0 ||
                    group_count > kMaxSparseCount ||
                    group_active_limit > kMaxSparseCount ||
                    cell_count > kMaxSparseCount ||
                    cell_active_limit > kMaxSparseCount ||
                    brick_cell_index >= static_cast<uint32_t>(cell_count) ||
                    brick_cell_index >= static_cast<uint32_t>(cell_active_limit) ||
                    cell_array == 0)
                {
                    continue;
                }

                result.plausible_checks++;
                if (brick_grid_context_is_plausible(address, brick_cell_index, brick_sub_index))
                {
                    result.found = true;
                    result.address = address;
                    result.detail = "matched sparse brick-grid context layout";
                    g_brick_grid_context_cached.store(address);
                    break;
                }
            }
            if (result.found)
            {
                break;
            }
        }

        result.duration_ms = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started)
                .count());
        if (!result.found && result.detail.empty())
        {
            result.detail = "no plausible sparse brick-grid context found within scan bounds";
        }
        return result;
    }

    BrickGridContextScanResult brick_grid_context_scan(uint32_t brick_cell_index, uint32_t brick_sub_index)
    {
        BrickGridContextScanResult result{};
        result.enabled = env_flag_enabled("BMF_BRICK_CONTEXT_SCAN_ENABLED");
        if (!result.enabled)
        {
            result.detail = "set BMF_BRICK_CONTEXT_SCAN_ENABLED=1 to run the explicit context scan";
            return result;
        }

        if (!env_flag_enabled("BMF_BRICK_CONTEXT_SCAN_SYNC_ENABLED"))
        {
            result.detail =
                "disabled because process-wide context scans can stall the dedicated server when run synchronously; "
                "use BMF_BRICK_CONTEXT_BACKGROUND_SCAN_ENABLED=1 to prime the cache off the game thread";
            return result;
        }

        return brick_grid_context_scan_memory(brick_cell_index, brick_sub_index);
    }

    bool brick_owner_context_scan_enabled()
    {
        return env_flag_enabled("BMF_BRICK_OWNER_CONTEXT_SCAN_ENABLED") ||
               env_flag_enabled("BMF_BRICK_CONTEXT_OWNER_SCAN_ENABLED");
    }

    bool brick_owner_context_check_candidate(BrickOwnerContextScanResult& result,
                                             uintptr_t address,
                                             std::string_view source,
                                             uint32_t brick_cell_index,
                                             uint32_t brick_sub_index)
    {
        if (address == 0 || !is_accessible_memory(address, 0x2E8))
        {
            return false;
        }

        result.plausible_checks++;
        if (!brick_grid_context_is_plausible(address, brick_cell_index, brick_sub_index))
        {
            return false;
        }

        result.found = true;
        result.address = address;
        result.source = std::string(source);
        result.detail = "matched sparse brick-grid context from bounded owner scan";
        g_brick_grid_context_cached.store(address);
        {
            std::lock_guard lock(g_brick_physical_mutex);
            g_brick_grid_context_cached_source = result.source;
        }
        return true;
    }

    BrickOwnerContextScanResult brick_owner_context_scan(uintptr_t owner_address,
                                                         uint32_t brick_cell_index,
                                                         uint32_t brick_sub_index)
    {
        BrickOwnerContextScanResult result{};
        result.enabled = brick_owner_context_scan_enabled();
        if (!result.enabled)
        {
            result.detail = "set BMF_BRICK_OWNER_CONTEXT_SCAN_ENABLED=1 to run the bounded owner context scan";
            return result;
        }
        if (owner_address == 0 || !is_accessible_memory(owner_address, 0x100))
        {
            result.detail = "brick owner memory is not accessible";
            return result;
        }

        const auto started = std::chrono::steady_clock::now();
        constexpr uintptr_t kOwnerDirectBytes = 0x1000;
        constexpr uintptr_t kNestedPointerBytes = 0x400;
        constexpr uintptr_t kStep = sizeof(uintptr_t);

        for (uintptr_t offset = 0; offset < kOwnerDirectBytes && !result.found; offset += kStep)
        {
            uintptr_t direct_address = 0;
            if (safe_offset(owner_address, offset, direct_address))
            {
                result.direct_candidates++;
                std::ostringstream source;
                source << "owner+0x" << std::uppercase << std::hex << offset;
                brick_owner_context_check_candidate(
                    result,
                    direct_address,
                    source.str(),
                    brick_cell_index,
                    brick_sub_index);
            }

            uint64_t pointer_value = 0;
            if (!read_u64_at(owner_address + offset, pointer_value))
            {
                continue;
            }
            const uintptr_t pointer_address = static_cast<uintptr_t>(pointer_value);
            if (pointer_address == 0)
            {
                continue;
            }

            result.pointer_candidates++;
            {
                std::ostringstream source;
                source << "owner.qword+0x" << std::uppercase << std::hex << offset;
                if (brick_owner_context_check_candidate(
                        result,
                        pointer_address,
                        source.str(),
                        brick_cell_index,
                        brick_sub_index))
                {
                    break;
                }
            }

            if (!is_accessible_memory(pointer_address, kNestedPointerBytes))
            {
                continue;
            }

            for (uintptr_t nested_offset = 0;
                 nested_offset < kNestedPointerBytes && !result.found;
                 nested_offset += kStep)
            {
                uint64_t nested_value = 0;
                if (!read_u64_at(pointer_address + nested_offset, nested_value))
                {
                    continue;
                }
                const uintptr_t nested_address = static_cast<uintptr_t>(nested_value);
                if (nested_address == 0)
                {
                    continue;
                }

                result.nested_pointer_candidates++;
                std::ostringstream source;
                source << "owner.qword+0x" << std::uppercase << std::hex << offset
                       << ".qword+0x" << nested_offset;
                brick_owner_context_check_candidate(
                    result,
                    nested_address,
                    source.str(),
                    brick_cell_index,
                    brick_sub_index);
            }
        }

        result.duration_ms = static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::steady_clock::now() - started)
                .count());
        if (!result.found && result.detail.empty())
        {
            result.detail = "no plausible sparse brick-grid context found from bounded owner scan";
        }
        return result;
    }

    bool brick_grid_context_background_scan_enabled()
    {
        return env_flag_enabled("BMF_BRICK_CONTEXT_BACKGROUND_SCAN_ENABLED") ||
               env_flag_enabled("BMF_BRICK_RUNTIME_CONTEXT_BACKGROUND_SCAN_ENABLED");
    }

    bool brick_grid_context_background_scan_start(uint32_t brick_cell_index,
                                                  uint32_t brick_sub_index)
    {
        if (!brick_grid_context_background_scan_enabled())
        {
            return false;
        }

        const uintptr_t cached_grid_context = g_brick_grid_context_cached.load();
        if (brick_grid_context_is_plausible(
                cached_grid_context,
                brick_cell_index,
                brick_sub_index))
        {
            return false;
        }

        bool expected = false;
        if (!g_brick_grid_context_background_scan_running.compare_exchange_strong(expected, true))
        {
            return false;
        }

        g_brick_grid_context_background_scan_requests.fetch_add(1);
        g_brick_grid_context_background_scan_cell_index.store(brick_cell_index);
        g_brick_grid_context_background_scan_sub_index.store(brick_sub_index);
        g_brick_grid_context_background_scan_address.store(0);
        g_brick_grid_context_background_scan_duration_ms.store(0);
        {
            std::lock_guard lock(g_brick_physical_mutex);
            g_brick_grid_context_background_scan_detail =
                "background sparse-grid context scan is running";
        }

        std::thread([brick_cell_index, brick_sub_index]() {
            const BrickGridContextScanResult scan =
                brick_grid_context_scan_memory(brick_cell_index, brick_sub_index);
            g_brick_grid_context_background_scan_duration_ms.store(scan.duration_ms);
            g_brick_grid_context_background_scan_address.store(scan.address);
            if (scan.found)
            {
                g_brick_grid_context_cached.store(scan.address);
                g_brick_grid_context_background_scan_completions.fetch_add(1);
                {
                    std::lock_guard lock(g_brick_physical_mutex);
                    g_brick_grid_context_cached_source = "background-scan";
                    g_brick_grid_context_background_scan_detail = scan.detail;
                }
            }
            else
            {
                g_brick_grid_context_background_scan_failures.fetch_add(1);
                {
                    std::lock_guard lock(g_brick_physical_mutex);
                    g_brick_grid_context_background_scan_detail = scan.detail;
                }
            }
            g_brick_grid_context_background_scan_running.store(false);
        }).detach();

        return true;
    }

    void append_brick_grid_context_candidate(std::ostringstream& out,
                                             size_t index,
                                             std::string_view name,
                                             uintptr_t address,
                                             uint32_t brick_cell_index,
                                             uint32_t brick_sub_index)
    {
        const std::string prefix = "grid_context_candidate." + std::to_string(index);
        out << prefix << ".name=" << json_escape(name) << "\n"
            << prefix << ".address=" << json_escape(pointer_hex(address)) << "\n";
        if (address == 0)
        {
            out << prefix << ".accessible=false\n"
                << prefix << ".plausible=false\n";
            return;
        }

        const bool accessible = is_accessible_memory(address, 0x2E8);
        out << prefix << ".accessible=" << (accessible ? "true" : "false") << "\n";
        if (!accessible)
        {
            out << prefix << ".plausible=false\n";
            return;
        }

        uint64_t group_array = 0;
        uint64_t group_bits_heap = 0;
        uint64_t cell_array = 0;
        uint64_t cell_bits_heap = 0;
        int32_t group_count = -1;
        int32_t group_active_limit = -1;
        int32_t cell_count = -1;
        int32_t cell_active_limit = -1;
        read_u64_at(address + 0x210, group_array);
        read_i32_at(address + 0x218, group_count);
        read_u64_at(address + 0x230, group_bits_heap);
        read_i32_at(address + 0x238, group_active_limit);
        read_u64_at(address + 0x2B8, cell_array);
        read_i32_at(address + 0x2C0, cell_count);
        read_u64_at(address + 0x2D8, cell_bits_heap);
        read_i32_at(address + 0x2E0, cell_active_limit);

        const bool cell_index_in_count =
            cell_count > 0 && brick_cell_index < static_cast<uint32_t>(cell_count);
        const bool cell_index_in_active_limit =
            cell_active_limit > 0 && brick_cell_index < static_cast<uint32_t>(cell_active_limit);
        bool cell_active = false;
        uintptr_t cell_bits_address = 0;
        const bool cell_bit_read = read_sparse_bit(
            address + 0x2C8,
            static_cast<uintptr_t>(cell_bits_heap),
            brick_cell_index,
            cell_active,
            cell_bits_address);

        uint32_t cell_group_index = UINT32_MAX;
        int32_t cell_sub_limit = -1;
        bool cell_entry_accessible = false;
        if (cell_index_in_count && cell_array != 0)
        {
            const uintptr_t cell_entry_address =
                static_cast<uintptr_t>(cell_array) + static_cast<uintptr_t>(brick_cell_index) * 0x28;
            cell_entry_accessible = is_accessible_memory(cell_entry_address, 0x28);
            if (cell_entry_accessible)
            {
                read_u32_at(cell_entry_address, cell_group_index);
                read_i32_at(cell_entry_address + 0x20, cell_sub_limit);
            }
        }

        const bool group_index_in_count =
            cell_group_index != UINT32_MAX &&
            group_count > 0 &&
            cell_group_index < static_cast<uint32_t>(group_count);
        const bool group_index_in_active_limit =
            cell_group_index != UINT32_MAX &&
            group_active_limit > 0 &&
            cell_group_index < static_cast<uint32_t>(group_active_limit);
        bool group_active = false;
        uintptr_t group_bits_address = 0;
        const bool group_bit_read =
            cell_group_index != UINT32_MAX &&
            read_sparse_bit(
                address + 0x220,
                static_cast<uintptr_t>(group_bits_heap),
                cell_group_index,
                group_active,
                group_bits_address);
        const bool sub_index_in_limit =
            cell_sub_limit > 0 && brick_sub_index < static_cast<uint32_t>(cell_sub_limit);
        const bool plausible =
            cell_index_in_count &&
            cell_index_in_active_limit &&
            cell_bit_read &&
            cell_active &&
            cell_entry_accessible &&
            group_index_in_count &&
            group_index_in_active_limit &&
            group_bit_read &&
            group_active &&
            sub_index_in_limit &&
            group_array != 0 &&
            is_accessible_memory(static_cast<uintptr_t>(group_array), 0x370);

        out << prefix << ".group_array=" << json_escape(pointer_hex(static_cast<uintptr_t>(group_array))) << "\n"
            << prefix << ".group_count=" << group_count << "\n"
            << prefix << ".group_active_limit=" << group_active_limit << "\n"
            << prefix << ".group_bits_address=" << json_escape(pointer_hex(group_bits_address)) << "\n"
            << prefix << ".cell_array=" << json_escape(pointer_hex(static_cast<uintptr_t>(cell_array))) << "\n"
            << prefix << ".cell_count=" << cell_count << "\n"
            << prefix << ".cell_active_limit=" << cell_active_limit << "\n"
            << prefix << ".cell_bits_address=" << json_escape(pointer_hex(cell_bits_address)) << "\n"
            << prefix << ".brick_cell_index_in_count=" << (cell_index_in_count ? "true" : "false") << "\n"
            << prefix << ".brick_cell_index_in_active_limit=" << (cell_index_in_active_limit ? "true" : "false") << "\n"
            << prefix << ".cell_bit_read=" << (cell_bit_read ? "true" : "false") << "\n"
            << prefix << ".cell_active=" << (cell_active ? "true" : "false") << "\n"
            << prefix << ".cell_entry_accessible=" << (cell_entry_accessible ? "true" : "false") << "\n"
            << prefix << ".cell_group_index=" << (cell_group_index == UINT32_MAX ? -1 : static_cast<int64_t>(cell_group_index)) << "\n"
            << prefix << ".cell_sub_limit=" << cell_sub_limit << "\n"
            << prefix << ".brick_sub_index_in_limit=" << (sub_index_in_limit ? "true" : "false") << "\n"
            << prefix << ".group_index_in_count=" << (group_index_in_count ? "true" : "false") << "\n"
            << prefix << ".group_index_in_active_limit=" << (group_index_in_active_limit ? "true" : "false") << "\n"
            << prefix << ".group_bit_read=" << (group_bit_read ? "true" : "false") << "\n"
            << prefix << ".group_active=" << (group_active ? "true" : "false") << "\n"
            << prefix << ".plausible=" << (plausible ? "true" : "false") << "\n";
    }

    void append_brick_grid_context_diagnostics(std::ostringstream& out,
                                               uintptr_t brick_address,
                                               uintptr_t owner_address,
                                               uintptr_t grid_context_address)
    {
        uint32_t brick_cell_index = 0;
        uint32_t brick_sub_index = 0;
        uint32_t brick_runtime_id = 0;
        read_u32_at(brick_address, brick_cell_index);
        read_u32_at(brick_address + 0x04, brick_sub_index);
        read_u32_at(brick_address + 0x24, brick_runtime_id);
        out << "brick_cell_index=" << brick_cell_index << "\n"
            << "brick_sub_index=" << brick_sub_index << "\n"
            << "brick_runtime_id_field=" << brick_runtime_id << "\n";

        std::vector<std::pair<std::string, uintptr_t>> candidates;
        auto add_candidate = [&candidates](std::string name, uintptr_t address)
        {
            if (address == 0)
            {
                return;
            }
            for (const auto& candidate : candidates)
            {
                if (candidate.second == address)
                {
                    return;
                }
            }
            candidates.emplace_back(std::move(name), address);
        };

        add_candidate("owner", owner_address);
        if (owner_address != 0)
        {
            for (uintptr_t offset = 0; offset <= 0x180; offset += 0x10)
            {
                add_candidate("owner+0x" + [&offset]()
                {
                    std::ostringstream s;
                    s << std::uppercase << std::hex << offset;
                    return s.str();
                }(), owner_address + offset);
            }
            for (uintptr_t offset = 0; offset <= 0x180; offset += 0x08)
            {
                uint64_t value = 0;
                if (read_u64_at(owner_address + offset, value) &&
                    value != 0 &&
                    is_accessible_memory(static_cast<uintptr_t>(value), 0x20))
                {
                    std::ostringstream name;
                    name << "owner.qword+0x" << std::uppercase << std::hex << offset;
                    add_candidate(name.str(), static_cast<uintptr_t>(value));
                }
            }
        }
        add_candidate("owner.qword+0x10.current", grid_context_address);

        const size_t max_candidates = std::min<size_t>(candidates.size(), 48);
        out << "grid_context_candidate_count=" << max_candidates << "\n";
        for (size_t index = 0; index < max_candidates; ++index)
        {
            append_brick_grid_context_candidate(
                out,
                index,
                candidates[index].first,
                candidates[index].second,
                brick_cell_index,
                brick_sub_index);
        }
    }

    void append_brick_grid_context_scan_result(std::ostringstream& out,
                                               const BrickGridContextScanResult& scan)
    {
        out << "grid_context_scan_enabled=" << (scan.enabled ? "true" : "false") << "\n"
            << "grid_context_scan_found=" << (scan.found ? "true" : "false") << "\n"
            << "grid_context_scan_address=" << json_escape(pointer_hex(scan.address)) << "\n"
            << "grid_context_scan_regions=" << scan.regions << "\n"
            << "grid_context_scan_scanned_bytes=" << scan.scanned_bytes << "\n"
            << "grid_context_scan_probes=" << scan.probes << "\n"
            << "grid_context_scan_plausible_checks=" << scan.plausible_checks << "\n"
            << "grid_context_scan_duration_ms=" << scan.duration_ms << "\n"
            << "grid_context_scan_detail=" << json_escape(scan.detail) << "\n";
    }

    void append_brick_owner_context_scan_result(std::ostringstream& out,
                                                const BrickOwnerContextScanResult& scan)
    {
        out << "owner_context_scan_enabled=" << (scan.enabled ? "true" : "false") << "\n"
            << "owner_context_scan_found=" << (scan.found ? "true" : "false") << "\n"
            << "owner_context_scan_address=" << json_escape(pointer_hex(scan.address)) << "\n"
            << "owner_context_scan_source=" << json_escape(scan.source) << "\n"
            << "owner_context_scan_direct_candidates=" << scan.direct_candidates << "\n"
            << "owner_context_scan_pointer_candidates=" << scan.pointer_candidates << "\n"
            << "owner_context_scan_nested_pointer_candidates=" << scan.nested_pointer_candidates << "\n"
            << "owner_context_scan_plausible_checks=" << scan.plausible_checks << "\n"
            << "owner_context_scan_duration_ms=" << scan.duration_ms << "\n"
            << "owner_context_scan_detail=" << json_escape(scan.detail) << "\n";
    }

    void append_brick_background_context_scan_status(std::ostringstream& out)
    {
        std::string detail;
        {
            std::lock_guard lock(g_brick_physical_mutex);
            detail = g_brick_grid_context_background_scan_detail;
        }
        out << "background_context_scan_enabled=" << (brick_grid_context_background_scan_enabled() ? "true" : "false") << "\n"
            << "background_context_scan_running=" << (g_brick_grid_context_background_scan_running.load() ? "true" : "false") << "\n"
            << "background_context_scan_requests=" << g_brick_grid_context_background_scan_requests.load() << "\n"
            << "background_context_scan_completions=" << g_brick_grid_context_background_scan_completions.load() << "\n"
            << "background_context_scan_failures=" << g_brick_grid_context_background_scan_failures.load() << "\n"
            << "background_context_scan_address=" << json_escape(pointer_hex(g_brick_grid_context_background_scan_address.load())) << "\n"
            << "background_context_scan_cell_index=" << g_brick_grid_context_background_scan_cell_index.load() << "\n"
            << "background_context_scan_sub_index=" << g_brick_grid_context_background_scan_sub_index.load() << "\n"
            << "background_context_scan_duration_ms=" << g_brick_grid_context_background_scan_duration_ms.load() << "\n"
            << "background_context_scan_detail=" << json_escape(detail) << "\n";
    }

    std::string brick_physical_inspect_text(uint32_t brick_id)
    {
        std::ostringstream out;
        out << "Brick physical state\n"
            << "source=BMFSocketBrickPhysical\n"
            << "operation=inspect\n"
            << "brick_id=" << brick_id << "\n";

        uintptr_t module_base = 0;
        uintptr_t registry_address = 0;
        uintptr_t brick_address = 0;
        std::string code;
        std::string detail;
        const bool found = brick_physical_lookup(
            brick_id, module_base, registry_address, brick_address, code, detail);

        out << "ok=" << (found ? "true" : "false") << "\n"
            << "code=" << code << "\n"
            << "module_base=" << json_escape(pointer_hex(module_base)) << "\n"
            << "registry_address=" << json_escape(pointer_hex(registry_address)) << "\n"
            << "brick_address=" << json_escape(pointer_hex(brick_address)) << "\n";

        if (!found)
        {
            out << "detail=" << json_escape(detail) << "\n";
            return out.str();
        }

        uint64_t array_base = 0;
        uint64_t owner_address = 0;
        uint64_t grid_context_address = 0;
        uint8_t visible = 0;
        uint8_t collision_channels = 0;
        uint8_t state_flags = 0;
        uint32_t brick_cell_index = 0;
        uint32_t brick_sub_index = 0;
        uint32_t slot_id = 0;

        read_u64_at(module_base + kBrickArrayBaseOffset, array_base);
        read_u64_at(brick_address + kBrickOwnerOffset, owner_address);
        if (owner_address != 0 && is_accessible_memory(static_cast<uintptr_t>(owner_address), 0x18))
        {
            read_u64_at(static_cast<uintptr_t>(owner_address) + 0x10, grid_context_address);
        }
        read_u8_at(brick_address + kBrickVisibleOffset, visible);
        read_u8_at(brick_address + kBrickCollisionChannelsOffset, collision_channels);
        read_u8_at(brick_address + kBrickStateFlagsOffset, state_flags);
        read_u32_at(brick_address, brick_cell_index);
        read_u32_at(brick_address + 0x04, brick_sub_index);
        if (array_base != 0 &&
            brick_address >= static_cast<uintptr_t>(array_base) &&
            ((brick_address - static_cast<uintptr_t>(array_base)) % kBrickRuntimeStride) == 0)
        {
            slot_id = static_cast<uint32_t>(
                (brick_address - static_cast<uintptr_t>(array_base)) / kBrickRuntimeStride);
        }

        bool has_original = false;
        BrickPhysicalOriginal original{};
        const uintptr_t cached_grid_context = g_brick_grid_context_cached.load();
        std::string cached_grid_context_source;
        std::string context_hook_error;
        {
            std::lock_guard lock(g_brick_physical_mutex);
            const auto found_original = g_brick_physical_originals.find(brick_id);
            if (found_original != g_brick_physical_originals.end())
            {
                has_original = found_original->second.captured;
                original = found_original->second;
            }
            cached_grid_context_source = g_brick_grid_context_cached_source;
            context_hook_error = g_brick_runtime_context_hook_error;
        }

        out << "array_base_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(array_base))) << "\n"
            << "runtime_slot=" << slot_id << "\n"
            << "slot_matches_id=" << (slot_id == brick_id ? "true" : "false") << "\n"
            << "owner_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(owner_address))) << "\n"
            << "grid_context_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(grid_context_address))) << "\n"
            << "grid_context_accessible=" << (
                   grid_context_address != 0 &&
                   is_accessible_memory(static_cast<uintptr_t>(grid_context_address), 0x2D0)
                   ? "true"
                   : "false") << "\n"
            << "visible=" << static_cast<unsigned int>(visible) << "\n"
            << "collision_channels=" << static_cast<unsigned int>(collision_channels) << "\n"
            << "state_flags=" << static_cast<unsigned int>(state_flags) << "\n"
            << "original_captured=" << (has_original ? "true" : "false") << "\n"
            << "original_visible=" << static_cast<unsigned int>(original.visible) << "\n"
            << "original_collision_channels=" << static_cast<unsigned int>(original.collision_channels) << "\n";
        out << "context_hook_enabled=" << (brick_runtime_context_hooks_enabled() ? "true" : "false") << "\n"
            << "context_hooks_installed=" << (g_brick_runtime_context_hooks_installed.load() ? "true" : "false") << "\n"
            << "context_hook_error=" << json_escape(context_hook_error) << "\n"
            << "cached_grid_context_address=" << json_escape(pointer_hex(cached_grid_context)) << "\n"
            << "cached_grid_context_source=" << json_escape(cached_grid_context_source) << "\n"
            << "cached_grid_context_accessible=" << (
                   cached_grid_context != 0 && is_accessible_memory(cached_grid_context, 0x2E8)
                   ? "true"
                   : "false") << "\n"
            << "cached_grid_context_plausible=" << (
                   brick_grid_context_is_plausible(cached_grid_context, brick_cell_index, brick_sub_index)
                   ? "true"
                   : "false") << "\n"
            << "context_capture_hits=" << g_brick_context_capture_hits.load() << "\n"
            << "context_capture_rejects=" << g_brick_context_capture_rejects.load() << "\n"
            << "place_action_apply_hits=" << g_brick_place_action_apply_hits.load() << "\n"
            << "visibility_action_apply_hits=" << g_brick_visibility_action_apply_hits.load() << "\n"
            << "collision_action_apply_hits=" << g_brick_collision_action_apply_hits.load() << "\n"
            << "low_setter_hook_enabled=" << (brick_runtime_low_setter_context_hook_enabled() ? "true" : "false") << "\n"
            << "visibility_low_setter_hook_installed=" << (g_brick_visibility_low_setter_hook.installed.load() ? "true" : "false") << "\n"
            << "collision_low_setter_hook_installed=" << (g_brick_collision_low_setter_hook.installed.load() ? "true" : "false") << "\n"
            << "visibility_low_setter_hits=" << g_brick_visibility_low_setter_hits.load() << "\n"
            << "collision_low_setter_hits=" << g_brick_collision_low_setter_hits.load() << "\n";
        append_brick_background_context_scan_status(out);

        append_brick_grid_context_diagnostics(
            out,
            brick_address,
            static_cast<uintptr_t>(owner_address),
            static_cast<uintptr_t>(grid_context_address));
        if (brick_owner_context_scan_enabled())
        {
            append_brick_owner_context_scan_result(
                out,
                brick_owner_context_scan(
                    static_cast<uintptr_t>(owner_address),
                    brick_cell_index,
                    brick_sub_index));
        }
        if (env_flag_enabled("BMF_BRICK_CONTEXT_SCAN_ENABLED"))
        {
            append_brick_grid_context_scan_result(
                out,
                brick_grid_context_scan(brick_cell_index, brick_sub_index));
        }
        return out.str();
    }

    bool brick_physical_apply_visibility(uintptr_t set_visibility_address,
                                         uintptr_t brick_address,
                                         uintptr_t grid_context_address,
                                         uint8_t visible)
    {
        auto set_visibility = reinterpret_cast<BrickSetVisibilityFn>(set_visibility_address);
        __try
        {
            set_visibility(brick_address, grid_context_address, visible);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    bool brick_physical_apply_collision(uintptr_t set_collision_address,
                                        uintptr_t brick_address,
                                        uintptr_t grid_context_address,
                                        uint8_t collision_channels)
    {
        auto set_collision = reinterpret_cast<BrickSetCollisionChannelsFn>(set_collision_address);
        __try
        {
            set_collision(brick_address, grid_context_address, collision_channels);
        }
        __except (EXCEPTION_EXECUTE_HANDLER)
        {
            return false;
        }
        return true;
    }

    std::string brick_physical_set_text(uint32_t brick_id,
                                        int64_t visible_arg,
                                        int64_t collision_channels_arg,
                                        uintptr_t explicit_grid_context)
    {
        std::ostringstream out;
        out << "Brick physical state\n"
            << "source=BMFSocketBrickPhysical\n"
            << "operation=set\n"
            << "brick_id=" << brick_id << "\n"
            << "requested_visible_arg=" << visible_arg << "\n"
            << "requested_collision_channels=" << collision_channels_arg << "\n"
            << "requested_grid_context_override=" << json_escape(pointer_hex(explicit_grid_context)) << "\n";

        if (!brick_physical_set_enabled())
        {
            out << "ok=false\n"
                << "code=BRICK_PHYSICAL_SET_DISABLED\n"
                << "detail=set BMF_BRICK_RUNTIME_SET_ENABLED=1 to allow explicit brick visibility/collision mutation; BMF_TREE_PHYSICAL_SET_ENABLED=1 is accepted as a legacy alias\n";
            return out.str();
        }

        uintptr_t module_base = 0;
        uintptr_t registry_address = 0;
        uintptr_t brick_address = 0;
        std::string code;
        std::string detail;
        const bool found = brick_physical_lookup(
            brick_id, module_base, registry_address, brick_address, code, detail);
        out << "module_base=" << json_escape(pointer_hex(module_base)) << "\n"
            << "registry_address=" << json_escape(pointer_hex(registry_address)) << "\n"
            << "brick_address=" << json_escape(pointer_hex(brick_address)) << "\n";
        if (!found)
        {
            out << "ok=false\n"
                << "code=" << code << "\n"
                << "detail=" << json_escape(detail) << "\n";
            return out.str();
        }

        uint64_t owner_address = 0;
        uint64_t grid_context_address = 0;
        std::string grid_context_source = "none";
        uint8_t before_visible = 0;
        uint8_t before_collision_channels = 0;
        uint32_t brick_cell_index = 0;
        uint32_t brick_sub_index = 0;
        read_u64_at(brick_address + kBrickOwnerOffset, owner_address);
        if (owner_address != 0 && is_accessible_memory(static_cast<uintptr_t>(owner_address), 0x18))
        {
            read_u64_at(static_cast<uintptr_t>(owner_address) + 0x10, grid_context_address);
            if (grid_context_address != 0)
            {
                grid_context_source = "owner.qword+0x10";
            }
        }
        read_u8_at(brick_address + kBrickVisibleOffset, before_visible);
        read_u8_at(brick_address + kBrickCollisionChannelsOffset, before_collision_channels);
        read_u32_at(brick_address, brick_cell_index);
        read_u32_at(brick_address + 0x04, brick_sub_index);

        const bool context_hook_install_attempted = brick_runtime_context_hooks_enabled();
        const bool context_hook_install_ok = context_hook_install_attempted
            ? brick_runtime_context_hook_install()
            : false;
        const uintptr_t cached_grid_context = g_brick_grid_context_cached.load();
        if (explicit_grid_context != 0)
        {
            if (!env_flag_enabled("BMF_BRICK_RUNTIME_CONTEXT_OVERRIDE_ENABLED") &&
                !brick_runtime_low_setter_context_hook_enabled())
            {
                out << "ok=false\n"
                    << "code=BRICK_GRID_CONTEXT_OVERRIDE_DISABLED\n"
                    << "detail=set BMF_BRICK_RUNTIME_CONTEXT_OVERRIDE_ENABLED=1 or BMF_BRICK_RUNTIME_LOW_SETTER_HOOK_ENABLED=1 to use explicit diagnostic grid contexts\n";
                return out.str();
            }
            if (!brick_grid_context_is_plausible(explicit_grid_context, brick_cell_index, brick_sub_index))
            {
                out << "ok=false\n"
                    << "code=BRICK_GRID_CONTEXT_OVERRIDE_INVALID\n"
                    << "grid_context_address=" << json_escape(pointer_hex(explicit_grid_context)) << "\n"
                    << "brick_cell_index=" << brick_cell_index << "\n"
                    << "brick_sub_index=" << brick_sub_index << "\n"
                    << "detail=explicit diagnostic grid context did not match the requested brick\n";
                return out.str();
            }
            grid_context_address = explicit_grid_context;
            grid_context_source = "explicit-override";
            g_brick_grid_context_cached.store(explicit_grid_context);
            {
                std::lock_guard lock(g_brick_physical_mutex);
                g_brick_grid_context_cached_source = grid_context_source;
            }
        }
        else if (brick_grid_context_is_plausible(cached_grid_context, brick_cell_index, brick_sub_index))
        {
            grid_context_address = cached_grid_context;
            grid_context_source = "cached-action-context";
        }
        else if (brick_owner_context_scan_enabled())
        {
            const BrickOwnerContextScanResult scan = brick_owner_context_scan(
                static_cast<uintptr_t>(owner_address),
                brick_cell_index,
                brick_sub_index);
            if (scan.found)
            {
                grid_context_address = scan.address;
                grid_context_source = scan.source.empty() ? "owner-scan" : scan.source;
            }
        }
        else if (env_flag_enabled("BMF_BRICK_CONTEXT_SCAN_ENABLED"))
        {
            const BrickGridContextScanResult scan = brick_grid_context_scan(brick_cell_index, brick_sub_index);
            if (scan.found)
            {
                grid_context_address = scan.address;
                grid_context_source = "scan";
            }
        }
        const bool grid_context_available =
            brick_grid_context_is_plausible(
                static_cast<uintptr_t>(grid_context_address),
                brick_cell_index,
                brick_sub_index);

        BrickPhysicalOriginal original{};
        {
            std::lock_guard lock(g_brick_physical_mutex);
            auto& stored = g_brick_physical_originals[brick_id];
            if (!stored.captured)
            {
                stored.captured = true;
                stored.visible = before_visible;
                stored.collision_channels = before_collision_channels;
            }
            original = stored;
        }

        uint8_t target_visible = before_visible;
        bool visibility_requested = false;
        std::string visible_source = "unchanged";
        if (visible_arg >= 0)
        {
            visibility_requested = true;
            target_visible = visible_arg != 0 ? 1 : 0;
            visible_source = "argument";
        }
        else if (visible_arg == -2)
        {
            visibility_requested = true;
            target_visible = original.visible;
            visible_source = "captured";
        }

        uint8_t next_collision_channels = before_collision_channels;
        bool collision_requested = false;
        std::string collision_source = "unchanged";
        if (collision_channels_arg >= 0)
        {
            collision_requested = true;
            next_collision_channels = static_cast<uint8_t>(std::min<int64_t>(255, collision_channels_arg));
            collision_source = "argument";
        }
        else if (collision_channels_arg == -1 && original.captured)
        {
            collision_requested = true;
            next_collision_channels = original.collision_channels;
            collision_source = "captured";
        }

        const uintptr_t set_visibility_address = module_base + kBrickSetVisibilityOffset;
        const uintptr_t set_collision_address = module_base + kBrickSetCollisionChannelsOffset;
        bool visibility_attempted = false;
        bool visibility_succeeded = false;
        bool visibility_skipped = true;
        bool visibility_exception_after_apply = false;
        std::string visibility_skip_reason = "visibility unchanged";
        const char* visibility_method = "";
        if (visibility_requested && target_visible == before_visible)
        {
            visibility_skip_reason = "already target visible state";
        }
        else if (visibility_requested &&
            env_flag_enabled("BMF_BRICK_VISIBILITY_SET_ENABLED") &&
            !env_flag_enabled("BMF_BRICK_VISIBILITY_SET_DISABLED"))
        {
            if (!grid_context_available)
            {
                const bool background_context_scan_started =
                    brick_grid_context_background_scan_start(brick_cell_index, brick_sub_index);
                const bool background_context_scan_pending =
                    background_context_scan_started ||
                    g_brick_grid_context_background_scan_running.load();
                out << "ok=false\n"
                    << "code=" << (background_context_scan_pending
                           ? "BRICK_GRID_CONTEXT_SCAN_PENDING"
                           : "BRICK_GRID_CONTEXT_UNAVAILABLE") << "\n"
                    << "owner_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(owner_address))) << "\n"
                    << "grid_context_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(grid_context_address))) << "\n"
                    << "grid_context_source=" << json_escape(grid_context_source) << "\n"
                    << "background_context_scan_started=" << (background_context_scan_started ? "true" : "false") << "\n"
                    << "low_setter_hook_enabled=" << (brick_runtime_low_setter_context_hook_enabled() ? "true" : "false") << "\n"
                    << "visibility_low_setter_hook_installed=" << (g_brick_visibility_low_setter_hook.installed.load() ? "true" : "false") << "\n"
                    << "collision_low_setter_hook_installed=" << (g_brick_collision_low_setter_hook.installed.load() ? "true" : "false") << "\n"
                    << "visibility_low_setter_hits=" << g_brick_visibility_low_setter_hits.load() << "\n"
                    << "collision_low_setter_hits=" << g_brick_collision_low_setter_hits.load() << "\n"
                    << "context_capture_hits=" << g_brick_context_capture_hits.load() << "\n"
                    << "context_capture_rejects=" << g_brick_context_capture_rejects.load() << "\n";
                append_brick_background_context_scan_status(out);
                out << "detail=brick grid context pointer is required by Brickadia physical-state setters\n";
                return out.str();
            }
            if (!is_executable_memory(set_visibility_address))
            {
                out << "ok=false\n"
                    << "code=BRICK_VISIBILITY_SETTER_UNAVAILABLE\n"
                    << "set_visibility_address=" << json_escape(pointer_hex(set_visibility_address)) << "\n"
                    << "detail=Brickadia visibility setter function address is not executable\n";
                return out.str();
            }
            visibility_attempted = true;
            visibility_skipped = false;
            visibility_skip_reason.clear();
            visibility_method = "brickadia-setter";
            visibility_succeeded = brick_physical_apply_visibility(
                set_visibility_address,
                brick_address,
                static_cast<uintptr_t>(grid_context_address),
                target_visible);
            if (!visibility_succeeded)
            {
                uint8_t probed_visible = 0;
                read_u8_at(brick_address + kBrickVisibleOffset, probed_visible);
                if (probed_visible == target_visible)
                {
                    visibility_exception_after_apply = true;
                    visibility_succeeded = true;
                }
                else
                {
                    out << "ok=false\n"
                        << "code=BRICK_VISIBILITY_SET_EXCEPTION\n"
                        << "detail=Brickadia visibility setter raised a structured exception before applying the requested state\n"
                        << "after_visible=" << static_cast<unsigned int>(probed_visible) << "\n";
                    return out.str();
                }
            }
        }
        else if (visibility_requested &&
            env_flag_enabled("BMF_BRICK_VISIBILITY_DIRECT_WRITE_ENABLED") &&
            !env_flag_enabled("BMF_BRICK_VISIBILITY_DIRECT_WRITE_DISABLED"))
        {
            visibility_attempted = true;
            visibility_skipped = false;
            visibility_skip_reason.clear();
            visibility_method = "direct-byte-write";
            visibility_succeeded = write_u8_at(
                brick_address + kBrickVisibleOffset,
                target_visible);
            if (!visibility_succeeded)
            {
                out << "ok=false\n"
                    << "code=BRICK_VISIBILITY_DIRECT_WRITE_FAILED\n"
                    << "detail=direct visibility byte write failed\n";
                return out.str();
            }
        }
        else if (visibility_requested)
        {
            out << "ok=false\n"
                << "code=BRICK_VISIBILITY_SET_DISABLED\n"
                << "detail=set BMF_BRICK_VISIBILITY_DIRECT_WRITE_ENABLED=1 for diagnostic byte writes or BMF_BRICK_VISIBILITY_SET_ENABLED=1 for the unsafe Brickadia setter\n";
            return out.str();
        }

        bool collision_skipped = true;
        bool collision_attempted = false;
        bool collision_succeeded = false;
        std::string collision_skip_reason = collision_requested ? "no safe collision setter flag is enabled" : "collision unchanged";
        const char* collision_method = "";
        if (collision_requested && next_collision_channels == before_collision_channels)
        {
            collision_skip_reason = "already target collision state";
        }
        else if (collision_requested && env_flag_enabled("BMF_BRICK_COLLISION_SET_ENABLED"))
        {
            collision_attempted = true;
            collision_skipped = false;
            collision_skip_reason.clear();
            collision_method = "brickadia-setter";
            if (!grid_context_available)
            {
                const bool background_context_scan_started =
                    brick_grid_context_background_scan_start(brick_cell_index, brick_sub_index);
                const bool background_context_scan_pending =
                    background_context_scan_started ||
                    g_brick_grid_context_background_scan_running.load();
                out << "ok=false\n"
                    << "code=" << (background_context_scan_pending
                           ? "BRICK_GRID_CONTEXT_SCAN_PENDING"
                           : "BRICK_GRID_CONTEXT_UNAVAILABLE") << "\n"
                    << "owner_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(owner_address))) << "\n"
                    << "grid_context_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(grid_context_address))) << "\n"
                    << "grid_context_source=" << json_escape(grid_context_source) << "\n"
                    << "background_context_scan_started=" << (background_context_scan_started ? "true" : "false") << "\n"
                    << "low_setter_hook_enabled=" << (brick_runtime_low_setter_context_hook_enabled() ? "true" : "false") << "\n"
                    << "visibility_low_setter_hook_installed=" << (g_brick_visibility_low_setter_hook.installed.load() ? "true" : "false") << "\n"
                    << "collision_low_setter_hook_installed=" << (g_brick_collision_low_setter_hook.installed.load() ? "true" : "false") << "\n"
                    << "visibility_low_setter_hits=" << g_brick_visibility_low_setter_hits.load() << "\n"
                    << "collision_low_setter_hits=" << g_brick_collision_low_setter_hits.load() << "\n"
                    << "context_capture_hits=" << g_brick_context_capture_hits.load() << "\n"
                    << "context_capture_rejects=" << g_brick_context_capture_rejects.load() << "\n";
                append_brick_background_context_scan_status(out);
                out << "detail=brick grid context pointer is required by Brickadia physical-state setters\n";
                return out.str();
            }
            if (!is_executable_memory(set_collision_address))
            {
                out << "ok=false\n"
                    << "code=BRICK_COLLISION_SETTER_UNAVAILABLE\n"
                    << "set_collision_channels_address=" << json_escape(pointer_hex(set_collision_address)) << "\n"
                    << "detail=Brickadia collision setter function address is not executable\n";
                return out.str();
            }
            collision_succeeded = brick_physical_apply_collision(
                set_collision_address,
                brick_address,
                static_cast<uintptr_t>(grid_context_address),
                next_collision_channels);
            if (!collision_succeeded)
            {
                out << "ok=false\n"
                    << "code=BRICK_COLLISION_SET_EXCEPTION\n"
                    << "detail=Brickadia collision setter raised a structured exception\n";
                return out.str();
            }
        }
        else if (collision_requested &&
            env_flag_enabled("BMF_BRICK_COLLISION_DIRECT_WRITE_ENABLED") &&
            !env_flag_enabled("BMF_BRICK_COLLISION_DIRECT_WRITE_DISABLED"))
        {
            collision_attempted = true;
            collision_skipped = false;
            collision_skip_reason.clear();
            collision_method = "direct-byte-write";
            collision_succeeded = write_u8_at(
                brick_address + kBrickCollisionChannelsOffset,
                next_collision_channels);
            if (!collision_succeeded)
            {
                out << "ok=false\n"
                    << "code=BRICK_COLLISION_DIRECT_WRITE_FAILED\n"
                    << "detail=direct collision-channel byte write failed\n";
                return out.str();
            }
        }

        uint8_t after_visible = 0;
        uint8_t after_collision_channels = 0;
        read_u8_at(brick_address + kBrickVisibleOffset, after_visible);
        read_u8_at(brick_address + kBrickCollisionChannelsOffset, after_collision_channels);

        out << "ok=true\n"
            << "code=OK\n"
            << "owner_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(owner_address))) << "\n"
            << "grid_context_address=" << json_escape(pointer_hex(static_cast<uintptr_t>(grid_context_address))) << "\n"
            << "grid_context_source=" << json_escape(grid_context_source) << "\n"
            << "grid_context_available=" << (grid_context_available ? "true" : "false") << "\n"
            << "context_hook_enabled=" << (brick_runtime_context_hooks_enabled() ? "true" : "false") << "\n"
            << "context_hook_install_attempted=" << (context_hook_install_attempted ? "true" : "false") << "\n"
            << "context_hook_install_ok=" << (context_hook_install_ok ? "true" : "false") << "\n"
            << "context_hooks_installed=" << (g_brick_runtime_context_hooks_installed.load() ? "true" : "false") << "\n"
            << "cached_grid_context_address=" << json_escape(pointer_hex(cached_grid_context)) << "\n"
            << "context_capture_hits=" << g_brick_context_capture_hits.load() << "\n"
            << "context_capture_rejects=" << g_brick_context_capture_rejects.load() << "\n"
            << "place_action_apply_hits=" << g_brick_place_action_apply_hits.load() << "\n"
            << "visibility_action_apply_hits=" << g_brick_visibility_action_apply_hits.load() << "\n"
            << "collision_action_apply_hits=" << g_brick_collision_action_apply_hits.load() << "\n"
            << "low_setter_hook_enabled=" << (brick_runtime_low_setter_context_hook_enabled() ? "true" : "false") << "\n"
            << "visibility_low_setter_hook_installed=" << (g_brick_visibility_low_setter_hook.installed.load() ? "true" : "false") << "\n"
            << "collision_low_setter_hook_installed=" << (g_brick_collision_low_setter_hook.installed.load() ? "true" : "false") << "\n"
            << "visibility_low_setter_hits=" << g_brick_visibility_low_setter_hits.load() << "\n"
            << "collision_low_setter_hits=" << g_brick_collision_low_setter_hits.load() << "\n";
        append_brick_background_context_scan_status(out);
        out << "brick_cell_index=" << brick_cell_index << "\n"
            << "brick_sub_index=" << brick_sub_index << "\n"
            << "before_visible=" << static_cast<unsigned int>(before_visible) << "\n"
            << "before_collision_channels=" << static_cast<unsigned int>(before_collision_channels) << "\n"
            << "target_visible=" << static_cast<unsigned int>(target_visible) << "\n"
            << "target_collision_channels=" << static_cast<unsigned int>(next_collision_channels) << "\n"
            << "after_visible=" << static_cast<unsigned int>(after_visible) << "\n"
            << "after_collision_channels=" << static_cast<unsigned int>(after_collision_channels) << "\n"
            << "visibility_set_requested=" << (visibility_requested ? "true" : "false") << "\n"
            << "visibility_set_attempted=" << (visibility_attempted ? "true" : "false") << "\n"
            << "visibility_set_succeeded=" << (visibility_succeeded ? "true" : "false") << "\n"
            << "visibility_set_skipped=" << (visibility_skipped ? "true" : "false") << "\n"
            << "visibility_set_skip_reason=" << json_escape(visibility_skip_reason) << "\n"
            << "visibility_set_method=" << visibility_method << "\n"
            << "visibility_exception_after_apply=" << (visibility_exception_after_apply ? "true" : "false") << "\n"
            << "visible_source=" << visible_source << "\n"
            << "collision_set_requested=" << (collision_requested ? "true" : "false") << "\n"
            << "collision_set_attempted=" << (collision_attempted ? "true" : "false") << "\n"
            << "collision_set_succeeded=" << (collision_succeeded ? "true" : "false") << "\n"
            << "collision_set_skipped=" << (collision_skipped ? "true" : "false") << "\n"
            << "collision_set_method=" << collision_method << "\n"
            << "collision_set_skip_reason=" << json_escape(collision_skip_reason) << "\n"
            << "collision_channels_source=" << collision_source << "\n"
            << "original_visible=" << static_cast<unsigned int>(original.visible) << "\n"
            << "original_collision_channels=" << static_cast<unsigned int>(original.collision_channels) << "\n";
        return out.str();
    }

    void treecut_set_error(std::string value)
    {
        std::lock_guard lock(g_treecut_mutex);
        g_treecut_last_error = std::move(value);
    }

    bool treecut_native_install()
    {
        if (g_treecut_installed.load())
        {
            return true;
        }

        Unreal::UObject* function = find_treecut_melee_function();
        if (!function)
        {
            treecut_set_error("MulticastReplicateAcceleratedMeleeExplosion UFunction not found");
            return false;
        }

        const uintptr_t function_address = reinterpret_cast<uintptr_t>(function);
        const uintptr_t slot_address = function_address + kTreeCutFuncOffset;
        if (!is_accessible_memory(slot_address, sizeof(void*)))
        {
            treecut_set_error("UFunction Func slot is not accessible");
            g_treecut_function.store(function_address);
            g_treecut_slot.store(slot_address);
            return false;
        }

        void** slot = reinterpret_cast<void**>(slot_address);
        void* current = nullptr;
        std::memcpy(&current, slot, sizeof(current));
        if (current != reinterpret_cast<void*>(&treecut_native_detour) &&
            (!current || !is_executable_memory(reinterpret_cast<uintptr_t>(current))))
        {
            treecut_set_error("UFunction Func slot target is not executable");
            g_treecut_function.store(function_address);
            g_treecut_slot.store(slot_address);
            return false;
        }

        DWORD old_protect = 0;
        if (!VirtualProtect(slot, sizeof(void*), PAGE_EXECUTE_READWRITE, &old_protect))
        {
            treecut_set_error("VirtualProtect failed for UFunction Func slot: " + std::to_string(GetLastError()));
            g_treecut_function.store(function_address);
            g_treecut_slot.store(slot_address);
            return false;
        }

        void* previous = InterlockedExchangePointer(slot, reinterpret_cast<void*>(&treecut_native_detour));
        DWORD ignored = 0;
        VirtualProtect(slot, sizeof(void*), old_protect, &ignored);
        FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));

        if (previous == reinterpret_cast<void*>(&treecut_native_detour))
        {
            previous = reinterpret_cast<void*>(g_treecut_original.load());
        }
        if (!previous)
        {
            treecut_set_error("UFunction Func slot had no original function");
            g_treecut_function.store(function_address);
            g_treecut_slot.store(slot_address);
            return false;
        }

        g_treecut_function.store(function_address);
        g_treecut_slot.store(slot_address);
        g_treecut_original.store(reinterpret_cast<uintptr_t>(previous));
        g_treecut_installed.store(true);
        treecut_set_error("");
        return true;
    }

    void enqueue_treecut_event(std::string event_json)
    {
        std::lock_guard lock(g_treecut_mutex);
        if (g_treecut_queue.size() >= 512)
        {
            g_treecut_queue.pop_front();
            g_treecut_queue_drops.fetch_add(1);
        }
        g_treecut_queue.push_back(std::move(event_json));
    }

    std::string build_treecut_event_json(
        uint64_t sequence,
        void* context,
        uintptr_t locals,
        const double values[7])
    {
        const TreeCutResolvedTarget target = treecut_resolve_target_actor(values);
        TreeCutConsoleTagInfo console_tag_info;
        treecut_collect_console_tags_from_locals(locals, console_tag_info);
        treecut_merge_target_console_tag(console_tag_info, target);
        treecut_record_console_tag_info(console_tag_info);

        std::ostringstream out;
        out << std::setprecision(17)
            << "{"
            << "\"type\":\"treecut_hit\","
            << "\"source\":\"BMFSocketTreeCutNative\","
            << "\"event\":\"cityrpg.treecut.hit\","
            << "\"sequence\":" << sequence << ","
            << "\"timestamp\":\"" << json_escape(system_utc_iso()) << "\","
            << "\"function\":\"MulticastReplicateAcceleratedMeleeExplosion\","
            << "\"itemType\":\"handaxe\","
            << "\"itemVerified\":true,"
            << "\"contextAddress\":\"" << json_escape(pointer_hex(reinterpret_cast<uintptr_t>(context))) << "\","
            << "\"contextClassAddress\":\"" << json_escape(pointer_hex(g_treecut_last_context_class.load())) << "\","
            << "\"handaxeClassAddress\":\"" << json_escape(pointer_hex(g_treecut_handaxe_class.load())) << "\","
            << "\"localsAddress\":\"" << json_escape(pointer_hex(locals)) << "\","
            << "\"impact\":{\"x\":" << values[1] << ",\"y\":" << values[2] << ",\"z\":" << values[3] << "},"
            << "\"normal\":{\"x\":" << values[4] << ",\"y\":" << values[5] << ",\"z\":" << values[6] << "},"
            << "\"raw0\":" << values[0];
        write_treecut_console_tags_json(out, console_tag_info);
        write_treecut_target_json(out, target);
        out << "}";
        return out.str();
    }

    void __fastcall treecut_native_detour(void* context, void* stack, void* result)
    {
        g_treecut_hits.fetch_add(1);

        uintptr_t locals = 0;
        double values[7]{};
        const bool params_ok = read_treecut_params(stack, locals, values);
        if (!params_ok)
        {
            g_treecut_param_failures.fetch_add(1);
        }

        NativeFunc original = reinterpret_cast<NativeFunc>(g_treecut_original.load());
        if (original)
        {
            original(context, stack, result);
        }

        if (g_treecut_enabled.load() && params_ok)
        {
            if (!is_treecut_context_handaxe(context))
            {
                g_treecut_rejected_non_handaxe.fetch_add(1);
                return;
            }

            g_treecut_verified_handaxe_hits.fetch_add(1);
            const uint64_t sequence = g_treecut_events.fetch_add(1) + 1;
            try
            {
                enqueue_treecut_event(build_treecut_event_json(sequence, context, locals, values));
            }
            catch (...)
            {
                treecut_set_error("treecut event serialization failed");
            }
        }
    }

    std::vector<std::string> drain_treecut_native_events(size_t max_count)
    {
        if (max_count < 1)
        {
            max_count = 1;
        }
        if (max_count > 256)
        {
            max_count = 256;
        }

        std::vector<std::string> events;
        std::lock_guard lock(g_treecut_mutex);
        while (!g_treecut_queue.empty() && events.size() < max_count)
        {
            events.push_back(std::move(g_treecut_queue.front()));
            g_treecut_queue.pop_front();
        }
        return events;
    }

    std::string treecut_native_status_text()
    {
        std::lock_guard lock(g_treecut_mutex);
        std::ostringstream out;
        out << "Tree-cut native status\n"
            << "source=BMFSocketTreeCutNative\n"
            << "enabled=" << (g_treecut_enabled.load() ? "true" : "false") << "\n"
            << "installed=" << (g_treecut_installed.load() ? "true" : "false") << "\n"
            << "function=" << json_escape(pointer_hex(g_treecut_function.load())) << "\n"
            << "slot=" << json_escape(pointer_hex(g_treecut_slot.load())) << "\n"
            << "original=" << json_escape(pointer_hex(g_treecut_original.load())) << "\n"
            << "detour=" << json_escape(pointer_hex(reinterpret_cast<uintptr_t>(&treecut_native_detour))) << "\n"
            << "hits=" << g_treecut_hits.load() << "\n"
            << "events=" << g_treecut_events.load() << "\n"
            << "verified_handaxe_hits=" << g_treecut_verified_handaxe_hits.load() << "\n"
            << "rejected_non_handaxe=" << g_treecut_rejected_non_handaxe.load() << "\n"
            << "queued=" << g_treecut_queue.size() << "\n"
            << "queue_drops=" << g_treecut_queue_drops.load() << "\n"
            << "param_failures=" << g_treecut_param_failures.load() << "\n"
            << "target_resolve_radius=" << kTreeCutTargetResolveRadius << "\n"
            << "target_cache_candidates=" << g_treecut_target_cache.size() << "\n"
            << "target_cache_refreshes=" << g_treecut_target_cache_refreshes.load() << "\n"
            << "target_cache_scanned_objects=" << g_treecut_target_cache_scanned_objects.load() << "\n"
            << "target_cache_errors=" << g_treecut_target_cache_errors.load() << "\n"
            << "target_cache_last_refresh_ms=" << g_treecut_target_cache_last_refresh_ms.load() << "\n"
            << "target_resolve_attempts=" << g_treecut_target_resolve_attempts.load() << "\n"
            << "target_resolve_hits=" << g_treecut_target_resolve_hits.load() << "\n"
            << "target_resolve_misses=" << g_treecut_target_resolve_misses.load() << "\n"
            << "console_tag_hits=" << g_treecut_console_tag_hits.load() << "\n"
            << "console_tag_misses=" << g_treecut_console_tag_misses.load() << "\n"
            << "last_console_tag=" << json_escape(g_treecut_last_console_tag) << "\n"
            << "last_console_tag_source=" << json_escape(g_treecut_last_console_tag_source) << "\n"
            << "last_target_name=" << json_escape(g_treecut_last_target_name) << "\n"
            << "last_target_full_name=" << json_escape(g_treecut_last_target_full_name) << "\n"
            << "last_target_class=" << json_escape(g_treecut_last_target_class) << "\n"
            << "last_target_detail=" << json_escape(g_treecut_last_target_detail) << "\n"
            << "handaxe_class=" << json_escape(pointer_hex(g_treecut_handaxe_class.load())) << "\n"
            << "handaxe_class_resolved=" << (g_treecut_handaxe_class_resolved.load() ? "true" : "false") << "\n"
            << "handaxe_class_attempted=" << (g_treecut_handaxe_class_attempted.load() ? "true" : "false") << "\n"
            << "handaxe_class_source=" << json_escape(g_treecut_handaxe_class_source) << "\n"
            << "handaxe_class_detail=" << json_escape(g_treecut_handaxe_class_detail) << "\n"
            << "last_context=" << json_escape(pointer_hex(g_treecut_last_context.load())) << "\n"
            << "last_context_class=" << json_escape(pointer_hex(g_treecut_last_context_class.load())) << "\n"
            << "last_item_type=" << json_escape(g_treecut_last_item_type) << "\n"
            << "last_reject_reason=" << json_escape(g_treecut_last_reject_reason) << "\n"
            << "last_error=" << json_escape(g_treecut_last_error) << "\n";
        return out.str();
    }

    std::string treecut_resolve_handaxe_status_text()
    {
        resolve_treecut_handaxe_class();
        return treecut_native_status_text();
    }

    bool is_object_property(Unreal::FProperty* property)
    {
        if (!property)
        {
            return false;
        }

        try
        {
            auto field_class = property->GetClass();
            return field_class.IsValid() && field_class.HasAllCastFlags(Unreal::CASTCLASS_FObjectPropertyBase);
        }
        catch (...)
        {
            return false;
        }
    }

    Unreal::UObject* get_first_object_property_with_class_flags(Unreal::UObject* object, Unreal::EClassCastFlags flags)
    {
        if (!is_live_uobject(object))
        {
            return nullptr;
        }

        try
        {
            auto object_class = object->GetClassPrivate();
            if (!object_class)
            {
                return nullptr;
            }

            for (Unreal::FProperty* property : Unreal::TFieldRange<Unreal::FProperty>(
                     object_class,
                     Unreal::EFieldIterationFlags::IncludeSuper | Unreal::EFieldIterationFlags::IncludeDeprecated))
            {
                if (!is_object_property(property))
                {
                    continue;
                }

                auto value = property->ContainerPtrToValuePtr<Unreal::UObject*>(object);
                if (value && object_class_has_any_cast_flags(*value, flags))
                {
                    return *value;
                }
            }
        }
        catch (...)
        {
        }

        return nullptr;
    }

    struct NativePlayerLocation
    {
        std::string source_kind;
        std::string source_name;
        std::string source_full_name;
        std::string controller_name;
        std::string controller_full_name;
        std::string pawn_name;
        std::string pawn_full_name;
        double x = 0.0;
        double y = 0.0;
        double z = 0.0;
    };

    struct NativePlayerLocationScanStats
    {
        size_t scanned_objects = 0;
        size_t controller_candidates = 0;
        size_t controller_attempts = 0;
        size_t controller_errors = 0;
        size_t player_state_candidates = 0;
        size_t player_state_attempts = 0;
        size_t player_state_errors = 0;
        size_t pawn_candidates = 0;
        std::vector<std::string> sample_names;
        std::vector<std::string> sample_class_names;
        std::vector<std::string> playerish_sample_names;
    };

    bool maybe_player_controller_name(std::string_view value)
    {
        return contains_ascii_case_insensitive(value, "PlayerController") ||
               contains_ascii_case_insensitive(value, "BRPlayerController") ||
               contains_ascii_case_insensitive(value, "BP_PlayerController");
    }

    bool maybe_player_state_name(std::string_view value)
    {
        return contains_ascii_case_insensitive(value, "PlayerState") ||
               contains_ascii_case_insensitive(value, "BRPlayerState") ||
               contains_ascii_case_insensitive(value, "BP_PlayerState");
    }

    bool maybe_playerish_name(std::string_view value)
    {
        return contains_ascii_case_insensitive(value, "player") ||
               contains_ascii_case_insensitive(value, "controller") ||
               contains_ascii_case_insensitive(value, "state") ||
               contains_ascii_case_insensitive(value, "pawn") ||
               contains_ascii_case_insensitive(value, "figure");
    }

    bool try_push_pawn_location(std::vector<NativePlayerLocation>& results,
                                std::vector<Unreal::UObject*>& seen_sources,
                                Unreal::UObject* source,
                                Unreal::UObject* controller,
                                Unreal::UObject* pawn,
                                std::string_view source_kind)
    {
        if (!is_live_uobject(source) || !is_live_uobject(pawn))
        {
            return false;
        }
        if (std::find(seen_sources.begin(), seen_sources.end(), source) != seen_sources.end())
        {
            return false;
        }

        try
        {
            if (!object_is_actor(pawn) &&
                !object_class_has_any_cast_flags(pawn, Unreal::CASTCLASS_AActor))
            {
                return false;
            }

            Unreal::FVector vector;
            std::string source_kind_suffix;
            if (try_actor_k2_location(pawn, vector))
            {
                source_kind_suffix = ".K2_GetActorLocation";
            }
            else if (!try_actor_root_component_location(pawn, vector, source_kind_suffix))
            {
                return false;
            }

            const double x = vector.X();
            const double y = vector.Y();
            const double z = vector.Z();
            if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(z))
            {
                return false;
            }

            NativePlayerLocation location;
            location.source_kind = std::string(source_kind) + source_kind_suffix;
            location.source_name = narrow_string(source->GetName());
            location.source_full_name = narrow_string(source->GetFullName());
            if (is_live_uobject(controller))
            {
                location.controller_name = narrow_string(controller->GetName());
                location.controller_full_name = narrow_string(controller->GetFullName());
            }
            location.pawn_name = narrow_string(pawn->GetName());
            location.pawn_full_name = narrow_string(pawn->GetFullName());
            location.x = x;
            location.y = y;
            location.z = z;
            seen_sources.push_back(source);
            results.push_back(std::move(location));
            return true;
        }
        catch (...)
        {
            return false;
        }
    }

    bool try_push_controller_location(std::vector<NativePlayerLocation>& results,
                                      std::vector<Unreal::UObject*>& seen_sources,
                                      Unreal::UObject* controller)
    {
        if (!is_live_uobject(controller))
        {
            return false;
        }

        try
        {
            Unreal::UObject* pawn = get_object_property(controller, STR("Pawn"));
            if (!pawn)
            {
                pawn = get_object_property(controller, STR("AcknowledgedPawn"));
            }
            if (!pawn)
            {
                pawn = get_object_property(controller, STR("Character"));
            }
            if (!pawn)
            {
                pawn = get_first_object_property_with_class_flags(controller, Unreal::CASTCLASS_APawn);
            }
            return try_push_pawn_location(results, seen_sources, controller, controller, pawn, "controller");
        }
        catch (...)
        {
            return false;
        }
    }

    bool try_push_player_state_location(std::vector<NativePlayerLocation>& results,
                                        std::vector<Unreal::UObject*>& seen_sources,
                                        Unreal::UObject* player_state)
    {
        if (!is_live_uobject(player_state))
        {
            return false;
        }

        try
        {
            Unreal::UObject* owner = get_object_property(player_state, STR("Owner"));
            Unreal::UObject* pawn = get_object_property(player_state, STR("PawnPrivate"));
            if (!pawn)
            {
                pawn = get_object_property(player_state, STR("Pawn"));
            }
            if (!pawn)
            {
                pawn = get_object_property(player_state, STR("Character"));
            }
            if (!pawn && owner)
            {
                pawn = get_object_property(owner, STR("Pawn"));
            }
            if (!pawn && owner)
            {
                pawn = get_object_property(owner, STR("AcknowledgedPawn"));
            }
            if (!pawn && owner)
            {
                pawn = get_object_property(owner, STR("Character"));
            }

            Unreal::UObject* source = owner ? owner : player_state;
            return try_push_pawn_location(results, seen_sources, source, owner, pawn, "player_state");
        }
        catch (...)
        {
            return false;
        }
    }

    NativePlayerLocationScanStats collect_controller_locations_by_scan(
        std::vector<NativePlayerLocation>& results,
        std::vector<Unreal::UObject*>& seen_sources)
    {
        NativePlayerLocationScanStats stats;
        std::vector<Unreal::UObject*> pawn_candidates;

        Unreal::UObjectGlobals::ForEachUObject([&](Unreal::UObject* object, int32_t, int32_t) {
            ++stats.scanned_objects;
            if (!object || object->HasAnyFlags(Unreal::RF_ClassDefaultObject))
            {
                return LoopAction::Continue;
            }

            try
            {
                const std::string object_name = narrow_string(object->GetName());
                const std::string object_full_name = narrow_string(object->GetFullName());
                std::string class_name;
                std::string class_full_name;
                if (auto object_class = object->GetClassPrivate())
                {
                    class_name = narrow_string(object_class->GetName());
                    class_full_name = narrow_string(object_class->GetFullName());
                }

                if (stats.sample_names.size() < 12 && !object_full_name.empty())
                {
                    stats.sample_names.push_back(object_full_name);
                }
                if (stats.sample_class_names.size() < 24 && !class_full_name.empty())
                {
                    stats.sample_class_names.push_back(class_full_name);
                }
                if (stats.playerish_sample_names.size() < 24 &&
                    (maybe_playerish_name(object_name) ||
                     maybe_playerish_name(object_full_name) ||
                     maybe_playerish_name(class_name) ||
                     maybe_playerish_name(class_full_name)))
                {
                    const std::string label = object_full_name.empty() ? object_name : object_full_name;
                    const std::string class_label = class_full_name.empty() ? class_name : class_full_name;
                    stats.playerish_sample_names.push_back(label + " class=" + class_label);
                }

                const bool controller_candidate =
                    object_class_has_any_cast_flags(object, Unreal::CASTCLASS_APlayerController) ||
                    maybe_player_controller_name(object_name) ||
                    maybe_player_controller_name(object_full_name) ||
                    maybe_player_controller_name(class_name) ||
                    maybe_player_controller_name(class_full_name);
                const bool player_state_candidate =
                    maybe_player_state_name(object_name) ||
                    maybe_player_state_name(object_full_name) ||
                    maybe_player_state_name(class_name) ||
                    maybe_player_state_name(class_full_name);
                const bool pawn_candidate = object_class_has_any_cast_flags(object, Unreal::CASTCLASS_APawn);

                if (pawn_candidate)
                {
                    ++stats.pawn_candidates;
                    pawn_candidates.push_back(object);
                }

                if (controller_candidate)
                {
                    ++stats.controller_candidates;
                    ++stats.controller_attempts;
                    try_push_controller_location(results, seen_sources, object);
                }

                if (player_state_candidate)
                {
                    ++stats.player_state_candidates;
                    ++stats.player_state_attempts;
                    try_push_player_state_location(results, seen_sources, object);
                }
            }
            catch (...)
            {
                ++stats.controller_errors;
            }

            return LoopAction::Continue;
        });

        if (results.empty())
        {
            for (Unreal::UObject* pawn : pawn_candidates)
            {
                try_push_pawn_location(results, seen_sources, pawn, nullptr, pawn, "pawn_scan");
            }
        }

        return stats;
    }

    void write_native_player_location_fields(std::ostringstream& out, const NativePlayerLocation& location)
    {
        out << "match=single-live-pawn\n"
            << "source_kind=" << json_escape(location.source_kind) << "\n"
            << "source_object=" << json_escape(location.source_name) << "\n"
            << "source_full_name=" << json_escape(location.source_full_name) << "\n"
            << "controller=" << json_escape(location.controller_name) << "\n"
            << "controller_full_name=" << json_escape(location.controller_full_name) << "\n"
            << "pawn=" << json_escape(location.pawn_name) << "\n"
            << "pawn_full_name=" << json_escape(location.pawn_full_name) << "\n"
            << std::fixed << std::setprecision(3)
            << "x=" << location.x << "\n"
            << "y=" << location.y << "\n"
            << "z=" << location.z << "\n";
    }

    void write_native_player_location_scan_lines(std::ostringstream& out, const std::vector<NativePlayerLocation>& locations)
    {
        for (size_t index = 0; index < locations.size(); ++index)
        {
            const NativePlayerLocation& location = locations[index];
            out << "position_" << (index + 1) << "="
                << "ok=true"
                << "|x=" << std::fixed << std::setprecision(3) << location.x
                << "|y=" << location.y
                << "|z=" << location.z
                << "|source_kind=" << json_escape(location.source_kind)
                << "|source_object=" << json_escape(location.source_name)
                << "|source_full_name=" << json_escape(location.source_full_name)
                << "|controller=" << json_escape(location.controller_name)
                << "|controller_full_name=" << json_escape(location.controller_full_name)
                << "|pawn=" << json_escape(location.pawn_name)
                << "|pawn_full_name=" << json_escape(location.pawn_full_name)
                << "\n";
        }
    }

    std::string build_native_player_location_text(std::string_view source_address, std::string_view requested_name)
    {
        std::vector<NativePlayerLocation> locations;
        std::vector<Unreal::UObject*> seen_sources;

        std::ostringstream out;
        out << "Native player location\n"
            << "requested_name=" << json_escape(requested_name) << "\n"
            << "source=BMFSocketPlayerLocation\n"
            << "source_address=" << json_escape(source_address) << "\n";

        if (is_native_location_scan_request(source_address))
        {
            if (!native_location_scan_enabled())
            {
                out << "native_scan=disabled\n"
                    << "ok=false\n"
                    << "detail=native location scan is disabled; provide a live UObject address or set BMF_NATIVE_LOCATION_SCAN=1 for diagnostics\n";
                return out.str();
            }

            const NativePlayerLocationScanStats stats = collect_controller_locations_by_scan(locations, seen_sources);
            out << "native_scan=enabled\n"
                << "native_location_count=" << locations.size() << "\n"
                << "scan_scanned_objects=" << stats.scanned_objects << "\n"
                << "scan_controller_candidates=" << stats.controller_candidates << "\n"
                << "scan_controller_attempts=" << stats.controller_attempts << "\n"
                << "scan_controller_errors=" << stats.controller_errors << "\n"
                << "scan_player_state_candidates=" << stats.player_state_candidates << "\n"
                << "scan_player_state_attempts=" << stats.player_state_attempts << "\n"
                << "scan_player_state_errors=" << stats.player_state_errors << "\n"
                << "scan_pawn_candidates=" << stats.pawn_candidates << "\n";

            if (locations.empty())
            {
                out << "ok=false\n"
                    << "detail=native scan found no pawn locations\n";
                return out.str();
            }

            out << "ok=true\n"
                << "detail=native scan collected player locations\n";
            write_native_player_location_scan_lines(out, locations);
            if (locations.size() == 1)
            {
                write_native_player_location_fields(out, locations.front());
            }
            return out.str();
        }

        out << "native_scan=disabled\n";

        uintptr_t parsed_source_address = 0;
        if (!parse_uobject_address(source_address, parsed_source_address) && !native_location_name_lookup_enabled())
        {
            out << "source_lookup=name_lookup_disabled\n"
                << "ok=false\n"
                << "detail=native location name lookup is disabled; provide a live UObject address or set BMF_NATIVE_LOCATION_NAME_LOOKUP=1 for diagnostics\n";
            return out.str();
        }

        Unreal::UObject* source = uobject_from_address_or_name(source_address);

        if (!is_live_uobject(source))
        {
            out << "ok=false\n"
                << "detail=source address does not point to a live UObject\n";
            return out.str();
        }

        bool resolved = try_push_controller_location(locations, seen_sources, source);
        if (!resolved)
        {
            resolved = try_push_player_state_location(locations, seen_sources, source);
        }
        if (!resolved)
        {
            resolved = try_push_pawn_location(locations, seen_sources, source, nullptr, source, "pawn");
        }

        out << "native_location_count=" << locations.size() << "\n";

        if (locations.empty())
        {
            out << "ok=false\n"
                << "detail=no pawn location resolved from source address\n"
                << "source_object=" << json_escape(narrow_string(source->GetName())) << "\n"
                << "source_full_name=" << json_escape(narrow_string(source->GetFullName())) << "\n"
                << "source_class=" << json_escape(object_class_name(source)) << "\n"
                << "source_class_full_name=" << json_escape(object_class_full_name(source)) << "\n"
                << "source_class_cast_flags=" << json_escape(object_class_cast_flags_hex(source)) << "\n"
                << "source_is_actor=" << (object_is_actor(source) ? "true" : "false") << "\n"
                << "source_is_pawn=" << (object_is_pawn(source) ? "true" : "false") << "\n";
            return out.str();
        }

        if (locations.size() > 1)
        {
            out << "ok=false\n"
                << "detail=multiple pawn locations resolved from source address\n";
            return out.str();
        }

        const NativePlayerLocation& location = locations.front();
        out << "ok=true\n";
        write_native_player_location_fields(out, location);
        return out.str();
    }

    class SocketRuntime
    {
      public:
        bool start(std::string host, uint16_t port, std::string token)
        {
            if (port == 0)
            {
                set_error("port must be greater than zero");
                return false;
            }

            {
                std::lock_guard lock(config_mutex_);
                host_ = std::move(host);
                port_ = port;
                token_ = std::move(token);
            }

            bool expected = false;
            if (!running_.compare_exchange_strong(expected, true))
            {
                return true;
            }

            worker_ = std::thread([this]() { worker_loop(); });
            return true;
        }

        void stop()
        {
            if (!running_.exchange(false))
            {
                return;
            }

            outbound_cv_.notify_all();
            if (worker_.joinable())
            {
                worker_.join();
            }
            connected_.store(false);
        }

        bool send_line(std::string line)
        {
            if (!running_.load())
            {
                set_error("socket runtime is not running");
                return false;
            }
            if (line.empty() || line.back() != '\n')
            {
                line.push_back('\n');
            }
            {
                std::lock_guard lock(outbound_mutex_);
                outbound_.push_back(std::move(line));
            }
            outbound_cv_.notify_one();
            return true;
        }

        std::vector<std::string> receive_lines(size_t max_count)
        {
            std::vector<std::string> lines;
            if (max_count == 0)
            {
                return lines;
            }
            std::lock_guard lock(inbound_mutex_);
            while (!inbound_.empty() && lines.size() < max_count)
            {
                lines.push_back(std::move(inbound_.front()));
                inbound_.pop_front();
            }
            return lines;
        }

        std::string status_json()
        {
            std::lock_guard config_lock(config_mutex_);
            std::lock_guard error_lock(error_mutex_);
            std::lock_guard in_lock(inbound_mutex_);
            std::lock_guard out_lock(outbound_mutex_);
            std::ostringstream out;
            out << "{"
                << "\"running\":" << (running_.load() ? "true" : "false") << ","
                << "\"connected\":" << (connected_.load() ? "true" : "false") << ","
                << "\"host\":\"" << json_escape(host_) << "\","
                << "\"port\":" << port_ << ","
                << "\"inboundQueued\":" << inbound_.size() << ","
                << "\"outboundQueued\":" << outbound_.size() << ","
                << "\"connects\":" << connects_.load() << ","
                << "\"disconnects\":" << disconnects_.load() << ","
                << "\"sentLines\":" << sent_lines_.load() << ","
                << "\"receivedLines\":" << received_lines_.load() << ","
                << "\"lastError\":\"" << json_escape(last_error_) << "\""
                << "}";
            return out.str();
        }

      private:
        void worker_loop()
        {
            WSADATA wsa_data{};
            const int wsa_result = ::WSAStartup(MAKEWORD(2, 2), &wsa_data);
            if (wsa_result != 0)
            {
                set_error("WSAStartup failed: " + std::to_string(wsa_result));
                running_.store(false);
                return;
            }

            while (running_.load())
            {
                SOCKET socket = connect_once();
                if (socket == INVALID_SOCKET)
                {
                    reconnect_pause();
                    continue;
                }

                connected_.store(true);
                connects_.fetch_add(1);
                set_error("");
                send_hello(socket);
                socket_loop(socket);
                ::closesocket(socket);
                connected_.store(false);
                disconnects_.fetch_add(1);
                reconnect_pause();
            }

            ::WSACleanup();
        }

        SOCKET connect_once()
        {
            std::string host;
            uint16_t port = 0;
            {
                std::lock_guard lock(config_mutex_);
                host = host_;
                port = port_;
            }

            addrinfo hints{};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;

            addrinfo* result = nullptr;
            const std::string port_text = std::to_string(port);
            const int getaddr_result = ::getaddrinfo(host.c_str(), port_text.c_str(), &hints, &result);
            if (getaddr_result != 0)
            {
                set_error("getaddrinfo failed: " + std::to_string(getaddr_result));
                return INVALID_SOCKET;
            }

            SOCKET connected_socket = INVALID_SOCKET;
            for (addrinfo* ptr = result; ptr != nullptr; ptr = ptr->ai_next)
            {
                SOCKET candidate = ::socket(ptr->ai_family, ptr->ai_socktype, ptr->ai_protocol);
                if (candidate == INVALID_SOCKET)
                {
                    continue;
                }
                if (::connect(candidate, ptr->ai_addr, static_cast<int>(ptr->ai_addrlen)) == 0)
                {
                    connected_socket = candidate;
                    break;
                }
                ::closesocket(candidate);
            }
            ::freeaddrinfo(result);

            if (connected_socket == INVALID_SOCKET)
            {
                set_error("connect failed: " + std::to_string(::WSAGetLastError()));
                return INVALID_SOCKET;
            }

            BOOL no_delay = TRUE;
            ::setsockopt(connected_socket, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&no_delay), sizeof(no_delay));
            return connected_socket;
        }

        void send_hello(SOCKET socket)
        {
            std::string token;
            {
                std::lock_guard lock(config_mutex_);
                token = token_;
            }
            const std::string hello =
                std::string("{\"type\":\"hello\",\"role\":\"bmf-native\",\"source\":\"BMFSocket\",\"version\":\"0.1.0\",\"token\":\"") +
                json_escape(token) +
                "\"}\n";
            send_all(socket, hello);
        }

        void socket_loop(SOCKET socket)
        {
            std::string read_buffer;
            while (running_.load())
            {
                if (!drain_outbound(socket))
                {
                    return;
                }

                fd_set read_set;
                FD_ZERO(&read_set);
                FD_SET(socket, &read_set);
                timeval timeout{};
                timeout.tv_sec = 0;
                timeout.tv_usec = 50000;
                const int selected = ::select(0, &read_set, nullptr, nullptr, &timeout);
                if (selected == SOCKET_ERROR)
                {
                    set_error("select failed: " + std::to_string(::WSAGetLastError()));
                    return;
                }
                if (selected == 0)
                {
                    continue;
                }

                char buffer[4096];
                const int received = ::recv(socket, buffer, sizeof(buffer), 0);
                if (received <= 0)
                {
                    if (received < 0)
                    {
                        set_error("recv failed: " + std::to_string(::WSAGetLastError()));
                    }
                    return;
                }
                read_buffer.append(buffer, static_cast<size_t>(received));
                consume_read_buffer(read_buffer);
            }
        }

        bool drain_outbound(SOCKET socket)
        {
            std::deque<std::string> batch;
            {
                std::lock_guard lock(outbound_mutex_);
                batch.swap(outbound_);
            }

            for (const std::string& line : batch)
            {
                if (!send_all(socket, line))
                {
                    set_error("send failed: " + std::to_string(::WSAGetLastError()));
                    std::lock_guard lock(outbound_mutex_);
                    outbound_.push_front(line);
                    return false;
                }
                sent_lines_.fetch_add(1);
            }
            return true;
        }

        void consume_read_buffer(std::string& buffer)
        {
            for (;;)
            {
                const size_t newline = buffer.find('\n');
                if (newline == std::string::npos)
                {
                    return;
                }
                std::string line = buffer.substr(0, newline);
                buffer.erase(0, newline + 1);
                if (!line.empty() && line.back() == '\r')
                {
                    line.pop_back();
                }
                if (!line.empty())
                {
                    push_inbound(std::move(line));
                    received_lines_.fetch_add(1);
                }
            }
        }

        void push_inbound(std::string line)
        {
            std::lock_guard lock(inbound_mutex_);
            inbound_.push_back(std::move(line));
            while (inbound_.size() > 4096)
            {
                inbound_.pop_front();
            }
        }

        void reconnect_pause()
        {
            for (int index = 0; running_.load() && index < 10; ++index)
            {
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
            }
        }

        void set_error(std::string value)
        {
            std::lock_guard lock(error_mutex_);
            last_error_ = std::move(value);
        }

        std::mutex config_mutex_;
        std::string host_ = "127.0.0.1";
        uint16_t port_ = 0;
        std::string token_;

        std::mutex inbound_mutex_;
        std::deque<std::string> inbound_;
        std::mutex outbound_mutex_;
        std::condition_variable outbound_cv_;
        std::deque<std::string> outbound_;

        std::mutex error_mutex_;
        std::string last_error_;

        std::thread worker_;
        std::atomic<bool> running_{false};
        std::atomic<bool> connected_{false};
        std::atomic<uint64_t> connects_{0};
        std::atomic<uint64_t> disconnects_{0};
        std::atomic<uint64_t> sent_lines_{0};
        std::atomic<uint64_t> received_lines_{0};
    };

    SocketRuntime g_socket;

    int lua_socket_start(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        const int argc = lua_gettop(state);
        std::string host = "127.0.0.1";
        if (argc >= 1 && lua_isstring(state, 1))
        {
            host = std::string(lua_tostring(state, 1));
        }
        int64_t port = 0;
        if (argc >= 2 && lua_isnumber(state, 2))
        {
            port = static_cast<int64_t>(lua_tointeger(state, 2));
        }
        std::string token;
        if (argc >= 3 && lua_isstring(state, 3))
        {
            token = std::string(lua_tostring(state, 3));
        }

        const bool ok = port > 0 && port <= 65535 && g_socket.start(host, static_cast<uint16_t>(port), token);
        lua.set_bool(ok);
        lua.set_string(g_socket.status_json());
        return 2;
    }

    int lua_socket_stop(const LuaMadeSimple::Lua& lua)
    {
        g_socket.stop();
        lua.set_bool(true);
        return 1;
    }

    int lua_socket_send(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        if (!lua_isstring(state, 1))
        {
            lua.set_bool(false);
            return 1;
        }
        size_t line_length = 0;
        const char* line = lua_tolstring(state, 1, &line_length);
        const bool ok = line != nullptr && g_socket.send_line(std::string(line, line_length));
        lua.set_bool(ok);
        return 1;
    }

    int lua_socket_receive(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        int64_t max_count = 64;
        if (lua_isnumber(state, 1))
        {
            max_count = static_cast<int64_t>(lua_tointeger(state, 1));
        }
        if (max_count < 1)
        {
            max_count = 1;
        }
        if (max_count > 512)
        {
            max_count = 512;
        }

        const auto lines = g_socket.receive_lines(static_cast<size_t>(max_count));
        lua_newtable(state);
        int index = 1;
        for (const std::string& line : lines)
        {
            lua_pushlstring(state, line.data(), line.size());
            lua_rawseti(state, -2, index++);
        }
        return 1;
    }

    int lua_socket_status(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string(g_socket.status_json());
        return 1;
    }

    int lua_socket_player_location(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        size_t address_length = 0;
        size_t requested_length = 0;
        const char* address = lua_isstring(state, 1) ? lua_tolstring(state, 1, &address_length) : "";
        const char* requested = lua_isstring(state, 2) ? lua_tolstring(state, 2, &requested_length) : "";
        lua.set_string(build_native_player_location_text(
            address ? std::string_view(address, address_length) : std::string_view(),
            requested ? std::string_view(requested, requested_length) : std::string_view()));
        return 1;
    }

    int lua_socket_describe_uobject(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        size_t address_length = 0;
        const char* address = lua_isstring(state, 1) ? lua_tolstring(state, 1, &address_length) : "";
        lua.set_string(build_native_uobject_description_text(
            address ? std::string_view(address, address_length) : std::string_view()));
        return 1;
    }

    int lua_socket_treecut_start(const LuaMadeSimple::Lua& lua)
    {
        const bool installed = treecut_native_install();
        g_treecut_enabled.store(installed);
        lua.set_bool(installed);
        lua.set_string(treecut_native_status_text());
        return 2;
    }

    int lua_socket_treecut_stop(const LuaMadeSimple::Lua& lua)
    {
        g_treecut_enabled.store(false);
        lua.set_bool(true);
        lua.set_string(treecut_native_status_text());
        return 2;
    }

    int lua_socket_treecut_status(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string(treecut_native_status_text());
        return 1;
    }

    int lua_socket_treecut_find_tag(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        size_t tag_length = 0;
        const char* tag = lua_isstring(state, 1) ? lua_tolstring(state, 1, &tag_length) : "";
        int64_t max_results = 8;
        int64_t max_scan = 250000;
        if (lua_isnumber(state, 2))
        {
            max_results = static_cast<int64_t>(lua_tointeger(state, 2));
        }
        if (lua_isnumber(state, 3))
        {
            max_scan = static_cast<int64_t>(lua_tointeger(state, 3));
        }
        if (max_results < 1)
        {
            max_results = 1;
        }
        if (max_results > 32)
        {
            max_results = 32;
        }
        if (max_scan < 1)
        {
            max_scan = 250000;
        }

        lua.set_string(treecut_find_console_tag_text(
            tag ? std::string_view(tag, tag_length) : std::string_view(),
            static_cast<size_t>(max_results),
            static_cast<uint64_t>(max_scan)));
        return 1;
    }

    int lua_socket_brick_physical_inspect(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        int64_t brick_id = 0;
        if (lua_isnumber(state, 1))
        {
            brick_id = static_cast<int64_t>(lua_tointeger(state, 1));
        }
        if (brick_id < 0)
        {
            brick_id = 0;
        }
        lua.set_string(brick_physical_inspect_text(static_cast<uint32_t>(brick_id)));
        return 1;
    }

    int lua_socket_brick_physical_set(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        int64_t brick_id = 0;
        if (lua_isnumber(state, 1))
        {
            brick_id = static_cast<int64_t>(lua_tointeger(state, 1));
        }
        if (brick_id < 0)
        {
            brick_id = 0;
        }

        int64_t visible = -1;
        if (lua_isboolean(state, 2))
        {
            visible = lua_toboolean(state, 2) != 0 ? 1 : 0;
        }
        else if (lua_isnumber(state, 2))
        {
            const int64_t raw_visible = static_cast<int64_t>(lua_tointeger(state, 2));
            visible = raw_visible < -1 ? -2 : raw_visible < 0 ? -1 : raw_visible != 0 ? 1 : 0;
        }
        else if (lua_isstring(state, 2))
        {
            size_t length = 0;
            const char* raw = lua_tolstring(state, 2, &length);
            const std::string value = ascii_lower(trim_ascii(raw ? std::string_view(raw, length) : std::string_view()));
            if (value == "restore" || value == "captured")
            {
                visible = -2;
            }
            else if (value == "unchanged" || value == "skip" || value == "same" || value == "")
            {
                visible = -1;
            }
            else
            {
                visible = value == "1" || value == "true" || value == "yes" || value == "on" || value == "visible" ? 1 : 0;
            }
        }

        int64_t collision_channels = -1;
        if (lua_isnumber(state, 3))
        {
            collision_channels = static_cast<int64_t>(lua_tointeger(state, 3));
        }
        else if (lua_isstring(state, 3))
        {
            size_t length = 0;
            const char* raw = lua_tolstring(state, 3, &length);
            const std::string value = ascii_lower(trim_ascii(raw ? std::string_view(raw, length) : std::string_view()));
            if (value == "unchanged" || value == "skip" || value == "same")
            {
                collision_channels = -2;
            }
            else if (value == "restore" || value == "captured" || value == "")
            {
                collision_channels = -1;
            }
            else
            {
                collision_channels = std::strtoll(value.c_str(), nullptr, 10);
            }
        }
        if (collision_channels < -2)
        {
            collision_channels = -2;
        }
        if (collision_channels > 255)
        {
            collision_channels = 255;
        }

        uintptr_t explicit_grid_context = 0;
        if (lua_isnumber(state, 4))
        {
            const lua_Integer raw_context = lua_tointeger(state, 4);
            if (raw_context > 0)
            {
                explicit_grid_context = static_cast<uintptr_t>(raw_context);
            }
        }
        else if (lua_isstring(state, 4))
        {
            size_t length = 0;
            const char* raw = lua_tolstring(state, 4, &length);
            const std::string value = trim_ascii(raw ? std::string_view(raw, length) : std::string_view());
            if (!value.empty())
            {
                explicit_grid_context = static_cast<uintptr_t>(
                    std::strtoull(value.c_str(), nullptr, 0));
            }
        }

        lua.set_string(brick_physical_set_text(
            static_cast<uint32_t>(brick_id),
            visible,
            collision_channels,
            explicit_grid_context));
        return 1;
    }

    int lua_socket_treecut_refresh_targets(const LuaMadeSimple::Lua& lua)
    {
        if (!env_flag_enabled("BMF_TREECUT_TARGET_REFRESH_ENABLED"))
        {
            treecut_set_error(
                "tree-cut target cache refresh disabled; set BMF_TREECUT_TARGET_REFRESH_ENABLED=1 "
                "only for manual diagnostics because it scans live UObjects");
            lua.set_bool(false);
            lua.set_string(treecut_native_status_text());
            return 2;
        }

        treecut_refresh_target_cache("lua-command");
        treecut_set_error("");
        lua.set_bool(true);
        lua.set_string(treecut_native_status_text());
        return 2;
    }

    int lua_socket_treecut_resolve_handaxe(const LuaMadeSimple::Lua& lua)
    {
        Unreal::UClass* handaxe_class = resolve_treecut_handaxe_class();
        lua.set_bool(handaxe_class != nullptr);
        lua.set_string(treecut_native_status_text());
        return 2;
    }

    int lua_socket_treecut_set_handaxe_class(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        size_t address_length = 0;
        size_t source_length = 0;
        const char* address = lua_isstring(state, 1) ? lua_tolstring(state, 1, &address_length) : "";
        const char* source = lua_isstring(state, 2) ? lua_tolstring(state, 2, &source_length) : "";
        const bool accepted = set_treecut_handaxe_class_from_address(
            address ? std::string_view(address, address_length) : std::string_view(),
            source ? std::string_view(source, source_length) : std::string_view());
        lua.set_bool(accepted);
        lua.set_string(treecut_native_status_text());
        return 2;
    }

    int lua_socket_treecut_drain(const LuaMadeSimple::Lua& lua)
    {
        lua_State* state = lua.get_lua_state();
        int64_t max_count = 64;
        if (lua_isnumber(state, 1))
        {
            max_count = static_cast<int64_t>(lua_tointeger(state, 1));
        }
        if (max_count < 1)
        {
            max_count = 1;
        }
        if (max_count > 256)
        {
            max_count = 256;
        }

        const auto events = drain_treecut_native_events(static_cast<size_t>(max_count));
        lua_newtable(state);
        int index = 1;
        for (const std::string& event : events)
        {
            lua_pushlstring(state, event.data(), event.size());
            lua_rawseti(state, -2, index++);
        }
        return 1;
    }

    int lua_socket_treecut_probe_start(const LuaMadeSimple::Lua& lua)
    {
        {
            std::lock_guard lock(g_treecut_probe_mutex);
            for (size_t index = 0; index < kTreeCutProbeSlotCount; ++index)
            {
                TreeCutProbeSlot& probe = g_treecut_probe_slots[index];
                probe.hits.store(0);
                probe.last_context.store(0);
                probe.last_stack.store(0);
                probe.last_tick_ms.store(0);
                g_treecut_probe_last_locals[index].store(0);
                g_treecut_probe_first_summary[index].clear();
                g_treecut_probe_last_summary[index].clear();
            }
        }
        const size_t installed = treecut_probe_install_all();
        g_treecut_probe_enabled.store(installed > 0);
        lua.set_bool(installed > 0);
        lua.set_string(treecut_probe_status_text());
        return 2;
    }

    int lua_socket_treecut_probe_stop(const LuaMadeSimple::Lua& lua)
    {
        g_treecut_probe_enabled.store(false);
        lua.set_bool(true);
        lua.set_string(treecut_probe_status_text());
        return 2;
    }

    int lua_socket_treecut_probe_status(const LuaMadeSimple::Lua& lua)
    {
        lua.set_string(treecut_probe_status_text());
        return 1;
    }

    class BMFSocketMod : public CppUserModBase
    {
      public:
        BMFSocketMod() : CppUserModBase()
        {
            ModName = STR("BMFSocket");
            ModVersion = STR("0.1.0");
            ModDescription = STR("Loopback socket transport for BMF Lua mods");
            ModAuthors = STR("CityRPG/BMF");
            std::printf("[BMFSocket] loaded\n");
        }

        ~BMFSocketMod() override
        {
            g_socket.stop();
        }

        auto on_lua_start(StringViewType,
                          LuaMadeSimple::Lua& lua,
                          LuaMadeSimple::Lua&,
                          LuaMadeSimple::Lua&,
                          LuaMadeSimple::Lua*) -> void override
        {
            lua.register_function("BMFSocketStart", lua_socket_start);
            lua.register_function("BMFSocketStop", lua_socket_stop);
            lua.register_function("BMFSocketSend", lua_socket_send);
            lua.register_function("BMFSocketReceive", lua_socket_receive);
            lua.register_function("BMFSocketStatus", lua_socket_status);
            lua.register_function("BMFSocketPlayerLocation", lua_socket_player_location);
            lua.register_function("BMFSocketDescribeUObject", lua_socket_describe_uobject);
            lua.register_function("BMFSocketTreeCutStart", lua_socket_treecut_start);
            lua.register_function("BMFSocketTreeCutStop", lua_socket_treecut_stop);
            lua.register_function("BMFSocketTreeCutStatus", lua_socket_treecut_status);
            lua.register_function("BMFSocketTreeCutFindTag", lua_socket_treecut_find_tag);
            lua.register_function("BMFSocketBrickPhysicalInspect", lua_socket_brick_physical_inspect);
            lua.register_function("BMFSocketBrickPhysicalSet", lua_socket_brick_physical_set);
            lua.register_function("BMFSocketTreeCutRefreshTargets", lua_socket_treecut_refresh_targets);
            lua.register_function("BMFSocketTreeCutResolveHandaxe", lua_socket_treecut_resolve_handaxe);
            lua.register_function("BMFSocketTreeCutSetHandaxeClass", lua_socket_treecut_set_handaxe_class);
            lua.register_function("BMFSocketTreeCutDrain", lua_socket_treecut_drain);
            lua.register_function("BMFSocketTreeCutProbeStart", lua_socket_treecut_probe_start);
            lua.register_function("BMFSocketTreeCutProbeStop", lua_socket_treecut_probe_stop);
            lua.register_function("BMFSocketTreeCutProbeStatus", lua_socket_treecut_probe_status);
            if (brick_runtime_context_hooks_enabled())
            {
                brick_runtime_context_hook_install();
            }
        }
    };
} // namespace

extern "C"
{
    __declspec(dllexport) CppUserModBase* start_mod()
    {
        return new BMFSocketMod();
    }

    __declspec(dllexport) void uninstall_mod(CppUserModBase* mod)
    {
        delete mod;
    }
}
