function Register()
    return table.concat({
        "56",
        "48 83 EC 40",
        "48 89 CE",
        "48 8B 05 ?? ?? ?? ??",
        "48 31 E0",
        "48 89 44 24 38",
        "48 89 54 24 20",
        "48 85 D2 74 ??",
        "44 0F B7 0A",
        "31 C0",
        "48 89 D1",
        "66 45 85 C9 74 ??",
        "45 0F B7 C9",
        "44 09 C8",
        "44 0F B7 49 02",
        "48 83 C1 02",
        "66 45 85 C9 75 ??",
        "83 F8 7F",
        "0F 97 C0",
    }, " ")
end

function OnMatchFound(MatchAddress)
    return MatchAddress
end
