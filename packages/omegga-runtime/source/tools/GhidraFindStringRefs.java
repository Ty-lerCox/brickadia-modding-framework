import java.util.ArrayList;
import java.util.List;
import java.nio.charset.StandardCharsets;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSetView;
import ghidra.program.model.data.DataType;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;

public class GhidraFindStringRefs extends GhidraScript {
  private String describeLocation(Address address) {
    Function function = getFunctionContaining(address);
    if (function != null) {
      return "func=" + function.getName() + " entry=" + function.getEntryPoint();
    }

    Instruction instruction = getInstructionContaining(address);
    if (instruction != null) {
      return "instruction=" + instruction;
    }

    Data data = getDataContaining(address);
    if (data != null) {
      return "data=" + data;
    }

    return "location=<unknown>";
  }

  private boolean isStringLike(Data data) {
    DataType dataType = data.getBaseDataType();
    if (dataType == null) {
      return false;
    }

    String name = dataType.getName().toLowerCase();
    String path = dataType.getPathName().toLowerCase();
    return name.contains("string") || path.contains("string");
  }

  private byte[] utf16le(String value) {
    byte[] ascii = value.getBytes(StandardCharsets.UTF_16LE);
    return ascii;
  }

  private void printRawRefs(String needle, Address address, String encodingLabel) {
    println("RAW_STRING " + needle + " @ " + address + " encoding=" + encodingLabel);
    Reference[] refs = getReferencesTo(address);
    if (refs.length == 0) {
      println("  refs=<none>");
      return;
    }

    for (Reference ref : refs) {
      Address from = ref.getFromAddress();
      println(
          "  from=" + from + " type=" + ref.getReferenceType() + " " + describeLocation(from));
    }
  }

  @Override
  protected void run() throws Exception {
    String[] args = getScriptArgs();
    if (args.length == 0) {
      printerr("usage: GhidraFindStringRefs <substring> [<substring> ...]");
      return;
    }

    List<String> needles = new ArrayList<>();
    List<String> loweredNeedles = new ArrayList<>();
    for (String arg : args) {
      needles.add(arg);
      loweredNeedles.add(arg.toLowerCase());
    }

    int hits = 0;

    DataIterator dataIterator = currentProgram.getListing().getDefinedData(true);
    while (dataIterator.hasNext()) {
      Data data = dataIterator.next();
      if (!isStringLike(data)) {
        continue;
      }

      Object value = data.getValue();
      if (value == null) {
        continue;
      }

      String rendered = value.toString();
      String lowered = rendered.toLowerCase();

      String matchedNeedle = null;
      for (String needle : loweredNeedles) {
        if (lowered.contains(needle)) {
          matchedNeedle = needle;
          break;
        }
      }

      if (matchedNeedle == null) {
        continue;
      }

      println("STRING " + matchedNeedle + " @ " + data.getAddress() + " => " + rendered);
      Reference[] refs = getReferencesTo(data.getAddress());
      if (refs.length == 0) {
        println("  refs=<none>");
      } else {
        for (Reference ref : refs) {
          Address from = ref.getFromAddress();
          println(
              "  from=" + from + " type=" + ref.getReferenceType() + " " + describeLocation(from));

          if (!ref.getReferenceType().isFlow()) {
            Data container = getDataContaining(from);
            if (container != null && !container.getAddress().equals(data.getAddress())) {
              println(
                  "    indirect-data="
                      + container.getAddress()
                      + " "
                      + describeLocation(container.getAddress()));

              for (Reference nested : getReferencesTo(container.getAddress())) {
                println(
                    "      nested-from="
                        + nested.getFromAddress()
                        + " type="
                        + nested.getReferenceType()
                        + " "
                        + describeLocation(nested.getFromAddress()));
              }
            }
          }
        }
      }

      hits++;
    }

    if (hits == 0) {
      Memory memory = currentProgram.getMemory();
      AddressSetView initialized = memory.getLoadedAndInitializedAddressSet();

      for (String needle : needles) {
        byte[] ascii = needle.getBytes(StandardCharsets.US_ASCII);
        byte[] wide = utf16le(needle);

        Address cursor = initialized.getMinAddress();
        while (cursor != null) {
          Address found = memory.findBytes(cursor, initialized.getMaxAddress(), ascii, null, true, monitor);
          if (found == null) {
            break;
          }
          printRawRefs(needle, found, "ascii");
          hits++;
          cursor = found.next();
        }

        cursor = initialized.getMinAddress();
        while (cursor != null) {
          Address found = memory.findBytes(cursor, initialized.getMaxAddress(), wide, null, true, monitor);
          if (found == null) {
            break;
          }
          printRawRefs(needle, found, "utf16le");
          hits++;
          cursor = found.next();
        }
      }
    }

    println("TOTAL_HITS=" + hits);
  }
}
