// Headless Ghidra script for openwbc3: dumps a program as greppable text files (MIT, part of openwbc3).
//   analyzeHeadless <projectDir> <project> -process <program> -postScript DumpProgram.java <outDir>
// (tools/dev/ghidra-dump.ps1 runs it). Writes into <outDir>:
//   index.tsv    address, name, size in bytes, callers (comma separated entry addresses) of every function
//   funcs/<address>.c   the decompiled C of each function (first line: "// <address> <name>")
//   strings.tsv  address, referencing function entries (comma separated), the string (\t \r \n \\ escaped)
// Before dumping, code pointers in the data sections that start no function yet (the entries of virtual function
// tables, callbacks kept in tables) get a function, so methods only reached through a table are dumped too.
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.TreeSet;

public class DumpProgram extends GhidraScript {
    @Override
    public void run() throws Exception {
        File out = new File(getScriptArgs()[0]);
        File funcDir = new File(out, "funcs");
        funcDir.mkdirs();
        println("MD5 " + currentProgram.getExecutableMD5());
        println("created " + createTableFunctions() + " functions at code pointers");

        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);
        ReferenceManager refs = currentProgram.getReferenceManager();
        int count = 0;
        try (PrintWriter index = new PrintWriter(new FileWriter(new File(out, "index.tsv")))) {
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                if (monitor.isCancelled()) break;
                String entry = f.getEntryPoint().toString();
                TreeSet<String> callers = new TreeSet<>();
                for (Function c : f.getCallingFunctions(monitor)) callers.add(c.getEntryPoint().toString());
                index.println(entry + "\t" + f.getName() + "\t" + f.getBody().getNumAddresses() + "\t"
                        + String.join(",", callers));
                if (f.isThunk() || f.isExternal()) continue;
                DecompileResults r = decomp.decompileFunction(f, 60, monitor);
                String c = r != null && r.getDecompiledFunction() != null
                        ? r.getDecompiledFunction().getC() : "// decompile failed\n";
                try (PrintWriter w = new PrintWriter(new FileWriter(new File(funcDir, entry + ".c")))) {
                    w.println("// " + entry + " " + f.getName());
                    w.print(c);
                }
                if (++count % 500 == 0) println("decompiled " + count);
            }
        }
        try (PrintWriter strings = new PrintWriter(new FileWriter(new File(out, "strings.tsv")))) {
            for (Data d : currentProgram.getListing().getDefinedData(true)) {
                if (!d.hasStringValue() || d.getValue() == null) continue;
                StringBuilder from = new StringBuilder();
                for (Reference ref : refs.getReferencesTo(d.getAddress())) {
                    Function f = getFunctionContaining(ref.getFromAddress());
                    from.append(f != null ? f.getEntryPoint() : ref.getFromAddress()).append(',');
                }
                String s = d.getValue().toString().replace("\\", "\\\\").replace("\t", "\\t").replace("\r", "\\r")
                        .replace("\n", "\\n");
                strings.println(d.getAddress() + "\t" + from + "\t" + s);
            }
        }
        println("DONE " + count);
    }

    // A 4-byte value in an initialised, non-executable block that points at an instruction no function contains, with
    // another such pointer right before or after it (tables, not stray constants), becomes a function entry.
    private int createTableFunctions() throws Exception {
        int created = 0;
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (b.isExecute() || !b.isInitialized()) continue;
            Address a = b.getStart();
            boolean prev = false;
            while (a.add(3).compareTo(b.getEnd()) <= 0 && !monitor.isCancelled()) {
                Address target = codeTarget(a);
                if (target != null) {
                    boolean next = a.add(7).compareTo(b.getEnd()) <= 0 && codeTarget(a.add(4)) != null;
                    if ((prev || next) && getFunctionContaining(target) == null) {
                        if (new CreateFunctionCmd(target).applyTo(currentProgram, monitor)) created++;
                    }
                }
                prev = target != null;
                a = a.add(4);
            }
        }
        return created;
    }

    private Address codeTarget(Address at) {
        try {
            long v = getInt(at) & 0xffffffffL;
            Address t = toAddr(v);
            MemoryBlock tb = currentProgram.getMemory().getBlock(t);
            if (tb == null || !tb.isExecute()) return null;
            Instruction ins = getInstructionAt(t);
            return ins != null ? t : null;
        } catch (Exception e) {
            return null;
        }
    }
}
