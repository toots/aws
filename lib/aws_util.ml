(* Copyright (c) 2010, barko 00336ea19fcb53de187740c490f764f4 All
   rights reserved.

   Redistribution and use in source and binary forms, with or without
   modification, are permitted provided that the following conditions are
   met:
   
   1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.

   2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the
   distribution.

   3. Neither the name of barko nor the names of contributors may be used
   to endorse or promote products derived from this software without
   specific prior written permission.

   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(* Miscellaneous *****************************************************************)

module Aws_utils(M : Aws_sigs.AWS_MONAD) =
  struct
    let remove_newline = 
      Pcre.replace ~rex:(Pcre.regexp "\n") ~templ:""
    
    let base64 str =
      (* the encoder is consumed by its use, so we have to recreated *)
      let b64_encoder = Cryptokit.Base64.encode_multiline () in
      let encoded = Cryptokit.transform_string b64_encoder str in
    
      (* we want to retain the trailing '=' characters, but eliminate the
         newlines.  Unfortunately, [encode_compact] has neither. *)
      remove_newline encoded
    
    
    let base64_decoder str =
      let b64_decoded = Cryptokit.Base64.decode () in 
      let decoded = Cryptokit.transform_string b64_decoded str in
      decoded 
    
    let colon_space (k, v) = k ^ ": " ^ v
    
    let encode_url ?(safe=false) str = 
      if not safe then Netencoding.Url.encode ~plus:false str
      else
        begin
          let strlist = ref [] in 
          for i = 0 to String.length str - 1 do 
            let c = Char.code (str.[i]) in 
            if (65 <= c && c <= 90) || (48 <= c && c <= 57 ) || (97 <= c && c <= 122) || (c = 126) || (c = 95) || (c = 46) || (c = 45) then  
    	    strlist := Printf.sprintf "%c" str.[i] :: !strlist 
            else 
    	    strlist :=  Printf.sprintf "%%%X" c :: !strlist 
          done ;
          String.concat "" (List.rev !strlist) 
        end
    
    let encode_key_equals_value ?(safe=false) kvs = 
      List.map (
        fun (k,v) -> 
          (encode_url ~safe k) ^ "=" ^ (encode_url ~safe v)
      ) kvs
    
    let file_size path =
      let s = Unix.stat path in
      s.Unix.st_size
    
    let xml_declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    
    let sort_assoc_list kv_list = 
      List.sort (fun (k1,_) (k2,_) -> String.compare k1 k2) kv_list
      
    let getenv_else_exit k = 
      try 
        Unix.getenv k
      with Not_found ->
        failwith (Printf.sprintf "environment variable %S not set\n%!" k)
    
    open Creds
    let creds_of_env () = {
      aws_access_key_id = getenv_else_exit "AWS_ACCESS_KEY_ID";
      aws_secret_access_key = getenv_else_exit "AWS_SECRET_ACCESS_KEY"
    }
      
    
    module C = CalendarLib.Calendar
    module P = CalendarLib.Printer.CalendarPrinter
    
    (* parse string of the format ["2009-12-04T22:33:47.279Z"], or ["Tue,
       30 Nov 2010 05:02:47 GMT"]; return seconds since Unix epoch. *)
    let unixfloat_of_amz_date_string str =
      try
        let year, month, day, hour, minute, second, millisecond =
          Scanf.sscanf str "%d-%d-%dT%d:%d:%d.%dZ" (
            fun year month day hour minute second millisecond ->
              year, month, day, hour, minute, second, millisecond
          ) 
        in
        let z = C.make year month day hour minute second in
        let t = C.to_unixfloat z  in
        let millis = (float_of_int millisecond) /. 1000. in
        t +. millis
    
      with Scanf.Scan_failure _ ->
        (* make a second attempt, now with a different format. ugh *)
        C.to_unixfloat (P.from_fstring "%A, %d %b %Y %H:%M:%S GMT" str)
    
    let amz_date_string_of_unixfloat f =
      let dt = P.sprint "%FT%T" (C.from_unixfloat f) in
      (* add trailing millis and 'Z' *)
      let millis = truncate ((f -. (float_of_int (truncate f))) *. 1000.) in
      Printf.sprintf "%s.%dZ" dt millis
    
    
    let date_string_of_unixfloat f =
      P.sprint "%F %T%z" (C.from_unixfloat f)
    
    let minutes_from_now minutes =
      let now = Unix.gettimeofday () in
      let seconds_from_now = minutes * 60 in
      let now_plus_minutes = now +. (float_of_int seconds_from_now) in
      amz_date_string_of_unixfloat now_plus_minutes
    
    let now_as_string () =
      amz_date_string_of_unixfloat (Unix.gettimeofday ())
    
    
    let rec list_map_i f list =
      loop f 0 [] list
    
    and loop f j accu = function
      | [] -> List.rev accu 
      | h :: t ->
        let m = f j h in
        loop f (j+1) (m::accu) t
    
    let read_contents inchan =
      let buf = Buffer.create 1024 in
      let rec loop () =
        M.bind (M.read ~count:1024 inchan)
        (fun s ->
          if s = ""  then
            M.return (Buffer.contents buf)
          else (
            Buffer.add_string buf s;
            loop ()
          ))
      in
      loop ()
    
    let file_contents path =
      let flags = [Unix.O_RDONLY] in
      M.bind (M.open_file ~flags ~mode:M.input path)
      (fun inchan ->
        M.bind (read_contents inchan )
        (fun contents ->
          M.bind (M.close inchan)
          (fun () ->
             M.return contents)))
    
      
    (* Post encoding *****************************************************************)
    
    let encode_post_url = Netencoding.Url.mk_url_encoded_parameters
end
