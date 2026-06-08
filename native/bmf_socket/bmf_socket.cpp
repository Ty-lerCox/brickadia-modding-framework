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
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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
