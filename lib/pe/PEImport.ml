open PEHeader

type import_directory_entry = {
    import_lookup_table_rva: int [@size 4];
    time_date_stamp: int [@size 4];
    forwarder_chain: int [@size 4];
    name_rva: int [@size 4];
    import_address_table_rva: int [@size 4];
    _name: string [@computed];
  } [@@deriving show]

let sizeof_import_directory_entry = 20 (* bytes *)

type import_lookup_table_entry = {
    ordinal_name_flag: bool [@size 1];
    ordinal_number: int [@size 16];
    hint_name_table_rva: int [@size 31];
  } [@@deriving show]

let get_import_directory_entry binary offset sections :import_directory_entry =
  let import_lookup_table_rva,o = Binary.u32o binary offset in
  let time_date_stamp,o = Binary.u32o binary o in
  let forwarder_chain,o = Binary.u32o binary o in
  let name_rva,o = Binary.u32o binary o in
  let import_address_table_rva = Binary.u32 binary o in
  let _name = try
      let _name_offset = PEUtils.find_offset name_rva sections in
      Binary.string binary _name_offset
    with Not_found -> ""
  in
  {import_lookup_table_rva;time_date_stamp;forwarder_chain;name_rva;import_address_table_rva;_name;}

let is_null entry =
  (entry.import_lookup_table_rva = 0) &&
    (entry.time_date_stamp = 0) &&
      (entry.forwarder_chain = 0) &&
        (entry.name_rva = 0) &&
          (entry.import_address_table_rva = 0)

type import_directory_table = import_directory_entry list [@@deriving show]

let get_import_directory_table binary offset sections=
  let rec loop acc i =
    let entry =
      get_import_directory_entry
        binary
        (offset + (i*sizeof_import_directory_entry))
        sections
    in
    if (is_null entry) then
      List.rev (entry::acc)
    else
      loop (entry::acc) (i+1)
  in loop [] 0

type t = {
    import_directory_table: import_directory_table;
  } [@@deriving show]

let get binary data_directories sections =
  let import_directory_table_rva = data_directories.import_table in
  let import_offset =
    try PEUtils.find_offset import_directory_table_rva sections with
    | Not_found -> 0
  in
  let import_directory_table =
    if (import_offset = 0) then
      []
    else
      get_import_directory_table binary import_offset sections
  in
  {
   import_directory_table; 
  }

let i0 = Binary.list_to_bytes [0x48; 0x31; 0x00; 0x00; 0x62; 0x31; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0xf8; 0x30; 0x00; 0x00;
0x10; 0x31; 0x00; 0x00; 0xde; 0x30; 0x00; 0x00; 0x32; 0x31; 0x00; 0x00; 0xc8; 0x30; 0x00; 0x00;
0xb4; 0x30; 0x00; 0x00; 0x8c; 0x31; 0x00; 0x00; 0x96; 0x31; 0x00; 0x00; 0xb6; 0x31; 0x00; 0x00;
0xc8; 0x31; 0x00; 0x00; 0xdc; 0x31; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x84; 0x30; 0x00; 0x00;
0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x3e; 0x31; 0x00; 0x00; 0x0c; 0x30; 0x00; 0x00;
0x78; 0x30; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x80; 0x31; 0x00; 0x00;
0x00; 0x30; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00;
0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x00; 0x48; 0x31; 0x00; 0x00; 0x62; 0x31; 0x00; 0x00;
0x00; 0x00; 0x00; 0x00; 0xf8; 0x30; 0x00; 0x00; 0x10; 0x31; 0x00; 0x00; 0xde; 0x30; 0x00; 0x00;
0x32; 0x31; 0x00; 0x00; 0xc8; 0x30; 0x00; 0x00; 0xb4; 0x30; 0x00; 0x00; 0x8c; 0x31; 0x00; 0x00;
0x96; 0x31; 0x00; 0x00; 0xb6; 0x31; 0x00; 0x00; 0xc8; 0x31; 0x00; 0x00; 0xdc; 0x31; 0x00; 0x00;
0x00; 0x00; 0x00; 0x00;]

let unit1 = get_import_directory_table i0 0
