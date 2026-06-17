from ghidra.program.model.symbol import RefType


def describe_location(addr):
    func = getFunctionContaining(addr)
    if func is not None:
        return "func={} entry={}".format(func.getName(), func.getEntryPoint())

    instruction = getInstructionContaining(addr)
    if instruction is not None:
        return "instruction={}".format(instruction)

    data = getDataContaining(addr)
    if data is not None:
        return "data={}".format(data)

    return "location=<unknown>"


def print_refs(label, addr, depth=0, visited=None):
    if visited is None:
        visited = set()

    if addr in visited:
        return
    visited.add(addr)

    indent = "  " * depth
    println("{}TARGET {} {}".format(indent, label, addr))

    refs = list(getReferencesTo(addr))
    if not refs:
        println("{}  refs=<none>".format(indent))
        return

    for ref in refs:
        from_addr = ref.getFromAddress()
        ref_type = ref.getReferenceType()
        println(
            "{}  from={} type={} {}".format(
                indent, from_addr, ref_type, describe_location(from_addr)
            )
        )

        # Some string addresses are referenced indirectly via pointer tables.
        # Follow data references one level so we can still recover the owning code.
        if depth == 0 and not ref_type.isFlow():
            data = getDataContaining(from_addr)
            if data is not None:
                print_refs("indirect-via-{}".format(from_addr), data.getAddress(), depth + 1, visited)


args = getScriptArgs()
if not args:
    printerr("usage: ghidra_xrefs.py <hex-address> [<hex-address> ...]")
    exit(1)

for arg in args:
    print_refs(arg, toAddr(arg))
