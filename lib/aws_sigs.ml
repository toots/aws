(* Various signatures *)

module type AWS_MONAD = 
  sig
    (* Sig for the monad. *)
    type 'a t
    type 'a channel
    val return : 'a -> 'a t
    val bind : 'a t -> ('a -> 'b t) -> 'b t
    val ( >>= ) : 'a t -> ('a -> 'b t) -> 'b t
    val try_bind : (unit -> 'a t) -> ('a -> 'b t) -> (exn -> 'b t) -> 'b t
    val fail : exn -> 'a t

    (* Sig for I/O operations. *)
    type input
    type input_channel = input channel
    type output
    type output_channel = output channel
    type 'a mode =
        private
      | Input
      | Output
    val input : input mode
    val output : output mode
    type file_name = string
    val open_file :
      ?buffer_size : int ->
      ?flags : Unix.open_flag list ->
      ?perm : Unix.file_perm ->
      mode : 'a mode ->
      file_name -> 'a channel t
    val read : ?count:int -> input_channel -> string t
    val close : 'a channel -> unit t
end

module type HTTP_CLIENT = 
  sig
    include AWS_MONAD

    type headers = (string * string) list
    type request_body =  [ `InChannel of int * input_channel
                         | `None
                         | `String of string ]
        
    exception Http_error of (int * headers * string)

    val get : ?headers:headers -> string -> (headers * string) t  
    
    val get_to_chan : ?headers:headers -> string -> output_channel -> headers t

    val post : ?headers:headers -> ?body:request_body -> string -> (headers * string) t  

    val put : ?headers:headers -> ?body:request_body -> string -> (headers * string) t  

    val delete : ?headers:headers -> string -> (headers * string) t  

    val head  : ?headers:headers -> string -> (headers * string) t  
  end
