(* 
  TODO: 
(-2): Add meta data to marshalled symbolmap/tol
(-1): /usr/lib/libmcheck.a with magic: 0x7f454c46 --- why does the .a file have an elf magic number?
(0) : Fix the suffix problem; doesn't work very well with linux, and osx frameworks won't get recognized either...
(1) : add this offset/polymorphic sorting, etc., to macho binary analysis to infer the size of objects per library...!
 *)

(*
for testing

#directory "../../_build/src/utils/";;
#directory "../../_build/src/mach/";;
#directory "../../_build/src/goblin/";;
#directory "../../_build/src/elf/";;

#load "Str.cma";;
#load "Unix.cma";;
#load "InputUtils.cmo";;
#load "Binary.cmo";;
#load "Leb128.cmo";;
#load "Generics.cmo";;
#load "Config.cmo";;
#load "Command.cmo";;
#load "RdrStorage.cmo";;

#load "Goblin.Symbol.cmo";;
#load "Goblin.cmo";;

#load "Mach.Exports.cmo";;
#load "Nlist.cmo";;
#load "CpuTypes.cmo";;
#load "BindOpcodes.cmo";;
#load "Mach.Imports.cmo";;
#load "MachHeader.cmo";;
#load "Version.cmo";;
#load "LoadCommand.cmo";;
#load "Fat.cmo";;
#load "ReadMach.cmo";;

#load "ToL.cmo";;

#load "ReadElf.cmo";;
#load "ElfReloc.cmo";;
#load "ElfHeader.cmo";;
#load "ElfConstants.cmo";;
#load "SymbolTable.cmo";;
#load "Dynamic.cmo";;
#load "SectionHeader.cmo";;
#load "ProgramHeader.cmo";;

#load "Rdr.Object.cmo";;
#load "Graph.cmo";;
*)
open Unix

(* also implement .a i guess
   --- ios will have a lot of those, burned into the binary, fun fun *)
let libraryish_suffixes = [".dylib"; ".so"; ".dll"; ".exe"]
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

(* osx specific framework reading; needs some (a lot) of tuning *)
let read_frameworks ~verbose dir stack =
  let dir_fd = Unix.opendir dir in
  let count = ref 0 in
  try
    while true do
      let f = dir ^ (Unix.readdir dir_fd) in
      let f_stat = Unix.lstat f in (* sees symbolic links *)
      match f_stat.st_kind with
      | Unix.S_DIR ->
	 if (Filename.check_suffix f "framework") then
	   let framework = Filename.chop_suffix (Filename.basename f) ".framework" in
	   Stack.push (f ^ Filename.dir_sep ^ framework) stack
	 else
	   ();
      | _ -> ();
    done
  with
  | End_of_file ->
     Unix.closedir dir_fd;
     if (verbose) then Printf.printf "Pushed %d libs from %s\n" !count dir
  | Unix_error (error,s1,s2) ->
     Unix.closedir dir_fd;
     if (verbose) then Printf.printf "Error: %s %s %s\n" (error_message error) s1 s2

let rec read_framework_dirs ~verbose:verbose ~frameworks:frameworks stack =
  match frameworks with
  | [] -> stack
  | dir::dirs ->
     let dir = if (Filename.check_suffix dir Filename.dir_sep) then
		 dir
	       else
		 dir ^ Filename.dir_sep
     in
     read_frameworks ~verbose:verbose dir stack;
     read_framework_dirs ~verbose:verbose ~frameworks:dirs stack

let build_lib_stack ~recursive:recursive ~verbose:verbose ~dirs:dirs =
  let stack = Stack.create() in
  let rec dir_loop dirs stack =
    match dirs with
    | [] -> stack
    | dir::dirs ->
       (* add the / if missing, as a convenience to the user *)
       let dir = if (Filename.check_suffix dir Filename.dir_sep) then
		   dir
		 else
		   dir ^ Filename.dir_sep
       in
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
  let oc = open_out (RdrStorage.get_path "stats") in
  output_string oc "symbol,count\n";
  Hashtbl.iter (fun a b ->
		let string = Printf.sprintf "%s,%d\n" a b in
		output_string oc string;
	       ) tbl;
  close_out oc

(* flattens symbol -> [libs] map to [goblin symbols] *)
let flatten map =  
  ToL.SystemSymbolMap.fold
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
       Buffer.add_string b
       (* need to not use mach export to string? *)
       @@ Goblin.Mach.Exports.mach_export_data_to_string
	    ~use_flags:false export;
       Buffer.add_string b "\n";
       loop exports
  in loop list

(* =================== *)
(* BUILDING *)
(* =================== *)
(* rdr -b *)


(* unit testing *)
(*  
let findf libs elem = 
  let lib = Goblin.Symbol.find_symbol_lib elem |> fst in
  List.mem lib libs

let sort = Goblin.Symbol.sort_symbols

let map = ToL.get ()
let flat = flatten_polymorphic_map_to_list map
let sflat = Goblin.Symbol.sort_symbols flat
let small = List.find_all  (findf ["/usr/lib/libz.1.dylib"; "/usr/lib/libobjc.A.dylib"]) flat
*)
