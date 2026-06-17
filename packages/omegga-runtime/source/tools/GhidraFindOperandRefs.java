import java.util.ArrayList;
import java.util.List;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressIterator;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.MemoryBlock;

public class GhidraFindOperandRefs extends GhidraScript {
  private String describeLocation(Address address) {
    Function function = getFunctionContaining(address);
    if (function != null) {
      return "func=" + function.getName() + " entry=" + function.getEntryPoint();
    }
    return "func=<none>";
  }

  @Override
  protected void run() throws Exception {
    String[] args = getScriptArgs();
    if (args.length == 0) {
      printerr("usage: GhidraFindOperandRefs <hex-address> [<hex-address> ...]");
      return;
    }

    List<Address> targets = new ArrayList<>();
    for (String arg : args) {
      targets.add(toAddr(arg));
    }

    InstructionIterator instructions = currentProgram.getListing().getInstructions(true);
    int hits = 0;
    while (instructions.hasNext()) {
      Instruction instruction = instructions.next();
      int operands = instruction.getNumOperands();
      for (int op = 0; op < operands; op++) {
        Object[] objects = instruction.getOpObjects(op);
        for (Object object : objects) {
          if (!(object instanceof Address)) {
            continue;
          }

          Address operandAddress = (Address) object;
          for (Address target : targets) {
            if (operandAddress.equals(target)) {
              println(
                  "REF target="
                      + target
                      + " from="
                      + instruction.getAddress()
                      + " op="
                      + op
                      + " "
                      + instruction
                      + " "
                      + describeLocation(instruction.getAddress()));
              hits++;
            }
          }
        }
      }
    }

    println("TOTAL_HITS=" + hits);
  }
}
