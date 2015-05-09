(* 
  TODO: 
(-1): /usr/lib/libmcheck.a with magic: 0x7f454c46 --- why does the .a file have an elf magic number?
(0) : Fix the suffix problem; doesn't work very well with linux, and osx frameworks won't get recognized either...
(1) : add this offset/polymorphic sorting, etc., to macho binary analysis to infer the size of objects per library...!
 *)

(*
for testing

#directory "/Users/matthewbarney/projects/binreader/_build/src/utils/";;
#directory "/Users/matthewbarney/projects/binreader/_build/src/mach/";;
#directory "/Users/matthewbarney/projects/binreader/_build/src/goblin/";;
#load "Unix.cma";;
#load "Binary.cmo";;
#load "InputUtils.cmo";;
#load "Version.cmo";;
#load "LoadCommand.cmo";;
#load "BindOpcodes.cmo";;
#load "Goblin.cmo";;
#load "GoblinSymbol.cmo";;
#load "Leb128.cmo";;
#load "Imports.cmo";;
#load "MachExports.cmo";;
#load "Macho.cmo";;
#load "MachHeader.cmo";;
#load "CpuTypes.cmo";;
#load "Generics.cmo";;
#load "Graph.cmo";;
#load "Object.cmo";;
#load "Fat.cmo";;
 *)
open Unix
open Config

module SystemSymbolMap = Map.Make(String)

(* eventually put .dll in there i guess *)
(* also implement .a i guess : fucking static libs
   --- ios will have a lot of those, burned into the binary, fun fun *)
let libraryish_suffixes = [".dylib"; ".so";]
(* 
TODO: banned suffixes, remove after solving problem with:
/usr/lib/libmcheck.a with magic: 0x7f454c46
 *)
let banned_suffixes = [".a"]			    

let has_libraryish_suffix string =
  List.fold_left (fun acc suffix ->
		  acc || (Filename.check_suffix string suffix)) false libraryish_suffixes

let has_banned_suffix string =
  List.fold_left (fun acc suffix ->
		  acc || (Filename.check_suffix string suffix)) false banned_suffixes

		 
(* rename this to object stack, wtf *)
let build_lib_stack recursive verbose dirs =
  let stack = Stack.create() in
  let rec dir_loop dirs stack =
    match dirs with
    | [] -> stack
    | dir::dirs ->
       (* add the / if missing, as a convenience to the user *)
       let dir = if (Filename.check_suffix dir Filename.dir_sep) then dir else dir ^ Filename.dir_sep in
       dir_loop dirs (read_dir dir stack)
  and read_dir dir stack =
    let dir_fd = Unix.opendir dir in
    let not_done = ref true in
    let count = ref 0 in
    while (!not_done) do
      try 
        let f = dir ^ (Unix.readdir dir_fd) in
        let f_stat = Unix.lstat f in (* lstat can see symbolic links *)
        match f_stat.st_kind with
        | Unix.S_REG ->
	   let base = Filename.basename f in
	   (*            if (has_libraryish_suffix base) then *)
	   if (not (has_banned_suffix base)) then
             begin
               if (verbose) then Printf.printf "using %s\n" f;
               incr count;
               Stack.push f stack
             end;
        | Unix.S_DIR ->
           if (recursive && not (Filename.check_suffix f ".")) then
             (* because read_dir returns the stack, maybe make this unit? *)
             ignore @@ read_dir (f ^ Filename.dir_sep) stack
           else
             ();
        (* ignore symbolic links and other file types *)
        | _ -> ();
      with 
      | End_of_file -> 
         not_done := false;
         Unix.closedir dir_fd;
         if (verbose) then Printf.printf "Pushed %d libs from %s\n" !count dir
      | Unix_error (error,s1,s2) ->
         (* probably surpress this error? *)
         if (verbose) then Printf.eprintf "Error: %s %s %s\n" (error_message error) s1 s2 
    done;
    stack
  in dir_loop dirs stack

let output_stats tbl =
  let oc = open_out (Output.with_dot_directory "stats") in
  output_string oc "symbol,count\n";
  Hashtbl.iter (fun a b ->
		let string = Printf.sprintf "%s,%d\n" a b in
		output_string oc string;
	       ) tbl;
  close_out oc

let build_polymorphic_map config =
  let dirs = config.base_symbol_map_directories in
  let recursive = config.recursive in
  let graph = config.graph in
  let verbose = config.verbose in
  let tbl = Hashtbl.create ((List.length dirs) * 100) in
  if (verbose) then Printf.printf "Building map...\n";
  let libstack = build_lib_stack recursive verbose dirs in
  if (verbose) then 
    begin
      Printf.printf "Total libs: %d\n" (Stack.length libstack);
      Printf.printf "... Done\n";
    end;
  let rec loop map lib_deps = 
    if (Stack.is_empty libstack) then 
      begin
	output_stats tbl;
        if (graph) then
          Graph.graph_lib_dependencies lib_deps;
        map
      end
    else
      let lib = Stack.pop libstack in
      let bytes = Object.get_bytes ~verbose:verbose lib in
      match bytes with
      (* could do a |> Mach.to_goblin here ? --- better yet, to goblin, then map building code after to avoid DRY violations *)
      | Object.Mach binary ->
         let binary = Mach.analyze {config with silent=true; filename=lib} binary in
	 let imports = binary.Mach.imports in
	 Array.iter (fun import ->
		     let symbol = import.MachImports.bi.MachImports.symbol_name in
		     if (Hashtbl.mem tbl symbol) then
		       let count = Hashtbl.find tbl symbol in
		       Hashtbl.replace tbl symbol (count + 1)
		     else
		       Hashtbl.add tbl symbol 1
		    ) imports;
         (* let symbols = MachExports.export_map_to_mach_export_data_list binary.Mach.exports in *)
         let symbols = binary.Mach.exports in
         (* now we fold over the export -> polymorphic variant list of [mach_export_data] mappings returned from above *)
         let map' = Array.fold_left (fun acc data -> 
				     (* this is bad, not checking for weird state of no export symbol name, but since i construct the data it isn't possible... right? *)
				     let symbol = GoblinSymbol.find_symbol_name data in
				     try 
				       (* if the symbol has a library-data mapping, then add the new lib-export data object to the export data list *)
				       let data' = SystemSymbolMap.find symbol acc in
				       SystemSymbolMap.add symbol (data::data') acc
				     with
				     | Not_found ->
					(* we don't have a record of this export symbol mapping; 
                                           create a new singleton list with the data
                                           (we already know the `Lib because MachExport's job is to add that) *)
					SystemSymbolMap.add symbol [data] acc
				    ) map symbols in
         loop map' ((binary.Mach.name, binary.Mach.libs)::lib_deps)
      | Object.Elf binary ->
         (* hurr durr iman elf *)
         let binary = Elf.analyze {config with silent=true; verbose=false; filename=lib} binary in
	 let imports = binary.Goblin.imports in
	 Array.iter (fun import ->
		     let symbol = import.Goblin.Import.name in
		     if (Hashtbl.mem tbl symbol) then
		       let count = Hashtbl.find tbl symbol in
		       Hashtbl.replace tbl symbol (count + 1)
		     else
		       Hashtbl.add tbl symbol 1
		    ) imports;
         let symbols = binary.Goblin.exports in
         (* now we fold over the export -> polymorphic variant list of [mach_export_data] mappings returned from above *)
         let map' = Array.fold_left
		      (fun acc data -> 
		       let symbol = data.Goblin.Export.name in
		       let data = GoblinSymbol.from_goblin_export data lib in (* yea, i know, whatever; 
                                                                   it keeps the cross-platform polymorphism, aieght *)
		       try 
			 (* if the symbol has a library-data mapping, then add the new lib-export data object to the export data list *)
			 let data' = SystemSymbolMap.find symbol acc in
			 SystemSymbolMap.add symbol (data::data') acc
		       with
		       | Not_found ->
			  (* we don't have a record of this export symbol mapping; 
                 create a new singleton list with the data (we already know the `Lib because MachExport's job is to add that)
                 except this is elf, so we also have to "promise" we did that there.  
                 Starting to become untenable and not very maintainable code
			   *)
			  SystemSymbolMap.add symbol [data] acc
		      ) map symbols in
         loop map' ((binary.Goblin.name, binary.Goblin.libs)::lib_deps)
      | _ ->
         loop map lib_deps
  in loop SystemSymbolMap.empty []

(* flattens symbol -> [libs] map to [mach_export_data] *)
let flatten_polymorphic_map_to_list map =  
  SystemSymbolMap.fold
    (fun key values acc ->
     (* list.fold acc in different arg pos than map.fold arg wtf *)
     List.fold_left
       (fun acc data ->
        data::acc) acc values
    ) map []

let polymorphic_list_to_string list =
  let b = Buffer.create ((List.length list) * 15) in
  let rec loop =
    function
    | [] -> Buffer.contents b
    | export::exports ->
       Buffer.add_string b @@ MachExports.mach_export_data_to_string ~use_flags:false export;
       Buffer.add_string b "\n";
       loop exports
  in loop list

let num_symbols = SystemSymbolMap.cardinal 

(* these no longer work because of massive api changes, good job matt *)
(* 
let print_map map =
  SystemSymbolMap.iter (fun symbol libs -> Printf.printf "%s -> %s\n" symbol 
                         @@ Generics.string_tuple_list_to_string libs
                       ) map



let map_to_string map =
  let b = Buffer.create ((num_symbols map) * 15) in
  SystemSymbolMap.iter (fun symbol libs -> Printf.sprintf "%s -> %s\n" symbol 
                         @@ Generics.string_tuple_list_to_string libs |> Buffer.add_string b
                       ) map;
  Buffer.contents b
 *)

let find_symbol key (map) = SystemSymbolMap.find key map

let print_map map = SystemSymbolMap.iter (
			fun key values ->
			Printf.printf "%s -> %s\n" key @@ (Generics.list_with_stringer (fun export -> GoblinSymbol.find_symbol_lib export) values)) map
					 
let use_symbol_map config =
  let symbol = config.search_term in
  try
    let f = Output.with_dot_directory "tol" in
    let ic = open_in_bin f in
    let map = Marshal.from_channel ic in
    (* =================== *)
    (* SEARCHING *)
    (* =================== *)
    if (config.search) then
      (* rdr -m -f <symbol_name> *)
      begin
        let recursive_message = if (config.recursive) then 
				  " (recursively)" 
				else ""
        in
        Printf.printf "searching %s%s for %s:\n"
		      (Generics.list_to_string 
			 ~omit_singleton_braces:true 
			 config.base_symbol_map_directories)
		      recursive_message
		      symbol; flush Pervasives.stdout;
        try
          find_symbol symbol map
          |> List.iter 
	       (fun data ->
		GoblinSymbol.print_symbol_data ~with_lib:true data;
		if (config.disassemble) then
		  begin
		    try
		    let lib = GoblinSymbol.find_symbol_lib data in
		    let startsym = GoblinSymbol.find_symbol_offset data in
		    let size = GoblinSymbol.find_symbol_size data in (* yo this is so dangerous cause may not be correct size... but I need to impress david and I definitely won't show him this line of code on Saturday ;) *)
		    let ic = open_in_bin lib in
		    seek_in ic startsym;
		    let code = really_input_string ic size |> Binary.to_hex_string in
		    close_in ic;
		    flush Pervasives.stdout;
		    Printf.printf "\t\n";
		    (* NOW FOR THE FUCKING HACKS *)
		    let command = Printf.sprintf "echo \"%s\" | /usr/bin/llvm-mc --disassemble" code in
		    ignore @@ Sys.command command;
		    with _ -> Printf.eprintf "could not disassemble #thug_life\n";
		  end
	       );
        with Not_found ->
	  Printf.printf "not found\n"; ()
      end
    else
      (* rdr -m -g *)
      let export_list = flatten_polymorphic_map_to_list map
                        |> GoblinSymbol.sort_symbols 
      in
      let export_list_string = polymorphic_list_to_string export_list in
      if (config.write_symbols) then
        begin
          let f = Output.with_dot_directory "symbols" in (* write to our .rdr *)
          let oc = open_out f in
          Printf.fprintf oc "%s" export_list_string;
          close_out oc;
        end
      else
	(* rdr -m*)
        Printf.printf "%s\n" export_list_string
  with (Sys_error _) ->
    Printf.eprintf "Searching without a marshalled system map is very slow (on older systems) and a waste of energy; run `rdr -b` first (it will build a marshalled system map, $HOME/.rdr/tol, for fast lookups), then search... Have a nice day!\n";
    flush Pervasives.stdout;
    exit 1

(* =================== *)
(* BUILDING *)
(* =================== *)
(* rdr -b *)
let build_symbol_map config =
  Printf.printf "Building system map... This can take a while, please be patient... "; flush Pervasives.stdout;
  let map = build_polymorphic_map config in
  let f = Output.with_dot_directory "tol" in
  let oc = open_out_bin f in
  Marshal.to_channel oc map [];
  close_out oc;
  Printf.printf "Done!\n"
