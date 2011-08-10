(* SDB API *)
(* william@corefarm.com *)

module Make = functor (HC : Aws_sigs.HTTP_CLIENT) -> 
struct 

  module C = CalendarLib.Calendar 
  module P = CalendarLib.Printer.CalendarPrinter
  module X = Xml


  open Lwt
  open Creds
  open Http_method

  module Util = Aws_util.Aws_utils(HC)

  exception Error of string

  let sprint = Printf.sprintf
  let print = Printf.printf
    
  let signed_request 
      ?region
      ?(http_method=`POST) 
      ?(http_uri="/")
      ?expires_minutes
      ?(safe=false)
      creds 
      params = 
    
    let http_host =
      match region with
        | Some r -> sprint "sdb.%s.amazonaws.com" r
        | None -> "sdb.amazonaws.com"
  in
    
    let params = 
      ("Version", "2009-04-15" ) ::
        ("SignatureVersion", "2") ::
        ("SignatureMethod", "HmacSHA1") ::
        ("AWSAccessKeyId", creds.aws_access_key_id) :: 
        params
    in
    
    let params = 
      match expires_minutes with
        | Some i -> ("Expires", Util.minutes_from_now i) :: params 
        | None -> ("Timestamp", Util.now_as_string ()) :: params
    in
    
    let signature = 
      let sorted_params = Util.sort_assoc_list params in
      let key_equals_value = Util.encode_key_equals_value ~safe sorted_params in
      let uri_query_component = String.concat "&" key_equals_value in
      let string_to_sign = String.concat "\n" [ 
        string_of_http_method http_method ;
        String.lowercase http_host ;
        http_uri ;
        uri_query_component 
      ]
      in 
      
      let hmac_sha1_encoder = Cryptokit.MAC.hmac_sha1 creds.aws_secret_access_key in
      let signed_string = Cryptokit.hash_string hmac_sha1_encoder string_to_sign in
      Util.base64 signed_string 
    in
    
    let params = ("Signature", signature) :: params in
    (http_host ^ http_uri), params
      

  (* XML readers *)  
      
  let error_msg code' body =
    match X.xml_of_string body with
      | X.E ("Response",_, (
               X.E ("Errors",_, [
                      X.E ("Error",_,[
                             X.E ("Code",_,[X.P code]);
                             X.E ("Message",_,[X.P message]); 
                             _ 
                           ]
                          )
                    ]
                   )
             ) :: _ ) -> `Error (code, message)
      | _ -> `Error ("unknown", body)


  let b64dec_if encoded s =
    if encoded then
      Util.base64_decoder s
    else
      s

  let b64enc_if encode s =
    if encode then
      Util.base64 s
    else
      s

  let domain_of_xml = function 
    | X.E ("DomainName", _, [ X.P domain_name ]) -> domain_name 
    | _ -> raise (Error "ListDomainsResult.domain")

  let list_domains_response_of_xml = function 
    | X.E ("ListDomainsResponse", _, [ 
             X.E ("ListDomainsResult", _, domains); 
             _ ]) -> List.map domain_of_xml domains
    | _ -> raise (Error "ListDomainsResult")
    
  let attributes_of_xml encoded = function 
    | X.E ("Attribute", _, [
             X.E ("Name", _, [ X.P name ]); 
             X.E ("Value", _, [ X.P value ]); 
           ]) -> 
        b64dec_if encoded name,  Some (b64dec_if encoded value)

    | X.E ("Attribute", _, [
             X.E ("Name", _, [ X.P name ]); 
             X.E ("Value", _, [ ]); 
           ]) -> 
        b64dec_if encoded name, None

    | _ -> raise (Error "Attribute 1")

  let get_attributes_response_of_xml encoded = function 
    | X.E ("GetAttributesResponse", _, [ 
             X.E ("GetAttributesResult", _, attributes); 
             _; 
           ]) -> List.map (attributes_of_xml encoded) attributes
    | _ -> raise (Error "GetAttributesResponse") 


  let attrs_of_xml encoded = function 
    | X.E ("Attribute", _ , children) -> 
      ( match children with 
        | [ X.E ("Name", _, [ X.P name ]) ;
            X.E ("Value", _, [ X.P value ]) ;
          ] ->  b64dec_if encoded name, Some (b64dec_if encoded value)
        | [ X.E ("Name", _, [ X.P name ]) ;
            X.E ("Value", _, [ ]) ;
          ] -> b64dec_if encoded name, None  
        | l -> raise (Error (sprint "fat list %d" (List.length l))) 
      )    
    | _ -> raise (Error "Attribute 3")

  let rec item_of_xml encoded acc token = function 
    | [] -> (acc, token)
    | X.E ("Item", _, (X.E ("Name", _, [ X.P name ]) :: attrs)) :: nxt -> 
        let a = List.map (attrs_of_xml encoded) attrs in
        item_of_xml encoded (((b64dec_if encoded name), a) :: acc) token nxt
    | X.E ("NextToken", _, [ X.P next_token ]) :: _ -> acc, (Some next_token) 
    | _ -> raise (Error "Item")
      
  let select_of_xml encoded = function 
    | X.E ("SelectResponse", _, [
             X.E ("SelectResult", _, items); 
             _ ;
           ]) -> item_of_xml encoded [] None items
    | _ -> raise (Error "SelectResponse")

  (* list all domains *)

  let list_domains creds ?token () = 
    let url, params = signed_request creds 
      (("Action", "ListDomains")
       :: match token with 
           None -> []
         | Some t -> [ "NextToken", t ]) in
    
    HC.try_bind
      (fun () ->
        HC.post ~body:(`String (Util.encode_post_url params)) url)
      (fun (header,body) ->
         let xml = X.xml_of_string body in
         HC.return (`Ok (list_domains_response_of_xml xml)))
      (function
       | HC.Http_error (code, _, body) ->  HC.return (error_msg code body)
       | e -> raise e)

  (* create domain *)

  let create_domain creds name = 
    let url, params = signed_request creds [
      "Action", "CreateDomain" ; 
      "DomainName", name
    ] in
    
    HC.try_bind
      (fun () -> 
        HC.post ~body:(`String (Util.encode_post_url params)) url)
      (fun (header,body) -> HC.return `Ok)
      (function 
        | HC.Http_error (code, _, body) -> 
          HC.return (error_msg code body)
        | e -> raise e)


  (* delete domain *)

  let delete_domain creds name = 
    let url, params = signed_request creds [
      "Action", "DeleteDomain" ; 
      "DomainName", name
    ] in
    
    HC.try_bind
      (fun () -> 
         HC.post ~body:(`String (Util.encode_post_url params)) url)
      (fun (header,body) -> HC.return `Ok)
      (function 
         | HC.Http_error (code, _, body) ->  
            HC.return (error_msg code body)
         | e -> raise e)


  (* put attributes *)
  
  let put_attributes ?(replace=false) ?(encode=true) creds domain item attrs = 
    let _, attrs' = List.fold_left (
      fun (i, acc) (name, value_opt) ->  
        let value_s = 
          match value_opt with
            | Some value -> b64enc_if encode value
            | None -> ""
        in
        let value_p = sprint "Attribute.%d.Value" i, value_s in
        let name_p = sprint "Attribute.%d.Name" i, b64enc_if encode name in
        let acc = 
          name_p :: value_p :: (
            if replace then 
              (sprint "Attribute.%d.Replace" i, "true") :: acc 
            else 
              acc
          ) in
        i+1, acc
    ) (1, []) attrs in
    let url, params = signed_request creds
      (("Action", "PutAttributes") 
       :: ("DomainName", domain)
       :: ("ItemName", b64enc_if encode item)
       :: attrs') in 
    HC.try_bind
      (fun () -> 
        HC.post ~body:(`String (Util.encode_post_url params)) url)
      (fun _ -> HC.return `Ok)
      (function
        | HC.Http_error (code, _, body) -> HC.return (error_msg code body)
        | e -> raise e)

  (* batch put attributes *)
      
  let batch_put_attributes ?(replace=false) ?(encode=true) creds domain items =
    let _, attrs' = List.fold_left 
      (fun (i, acc) (item_name, attrs) -> 
         let item_name_p = sprint "Item.%d.ItemName" i, b64enc_if encode item_name in
         let _, acc = List.fold_left (
           fun (j, acc) (name, value_opt) -> 
             let name_p = sprint "Item.%d.Attribute.%d.Name" i j, 
               b64enc_if encode name in
             let value_s =
               match value_opt with
                 | Some value -> b64enc_if encode value
                 | None -> "" in
             let value_p = sprint "Item.%d.Attribute.%d.Value" i j, value_s in
             let acc' = name_p :: value_p :: 
               if replace then 
                  (sprint "Item.%d.Attribute.%d.Replace" i j, "true") :: acc 
                else 
                  acc
             in
             j+1, acc'
         ) (1, item_name_p :: acc) attrs in 
         i+1, acc
      ) (1, []) items in 
    
    let url, params = signed_request creds
      (("Action", "BatchPutAttributes") 
       :: ("DomainName", domain)
       :: attrs') in 
    HC.try_bind
      (fun () -> 
        HC.post ~body:(`String (Util.encode_post_url params)) url)
      (fun (header,body) -> HC.return `Ok)
      (function 
        | HC.Http_error (code, _, body) ->  
            HC.return (error_msg code body)
        | e -> raise e)
    
  (* get attributes *)

  let get_attributes ?(encoded=true) creds domain ?attribute item = 
    let attribute_name_p =
      match attribute with 
        | None -> [] 
        | Some attribute_name -> 
            [ "AttributeName", (b64enc_if encoded attribute_name) ]
    in
    let url, params = signed_request creds (
      ("Action", "GetAttributes") :: 
        ("DomainName", domain) :: 
        ("ItemName", b64enc_if encoded item) ::
        attribute_name_p
    ) in
    HC.try_bind
      (fun () ->
         HC.post ~body:(`String (Util.encode_post_url params)) url)
      (fun (header,body) ->
         let xml = X.xml_of_string body in
         HC.return (`Ok (get_attributes_response_of_xml encoded xml)))
      (function 
        | HC.Http_error (code, _, body) -> HC.return (error_msg code body)
        | e -> raise e)
 
  (* delete attributes *)

  let delete_attributes ?(encode=true) creds domain item attrs = 
    let _, attrs' = List.fold_left (
      fun (i, acc) (name, value) -> 
        let name_p = sprint "Attribute.%d.Name" i, b64enc_if encode name in
        let value_p = sprint "Attribute.%d.Value" i, b64enc_if encode value in
        i+1, name_p :: value_p :: acc
    ) (0,[]) attrs in
    let url, params = signed_request creds
      (("Action", "DeleteAttributes") 
       :: ("DomainName", domain)
       :: ("ItemName", b64enc_if encode item)
       :: attrs') in 
    HC.try_bind
      (fun () -> 
         HC.post ~body:(`String (Util.encode_post_url params)) url)
      (fun (header,body) -> HC.return `Ok)
      (function 
        | HC.Http_error (code, _, body) ->
            HC.return (error_msg code body)
        | e -> raise e)
 
  (* select: TODO if [encode=true], encode references to values in the
     select [expression].  This might not be easy, as the [expression]
     will have to be deconstructed (parsed). Alternatively,
     [expression] is replaced with an expression type, which would
     make value substitutions easier. Neither would work for numerical
     constraints.  *)

  let select ?(consistent=false) ?(encoded=true) ?(token=None) creds expression =
    let url, params = signed_request ~safe:true creds
      (("Action", "Select") 
       :: ("SelectExpression", expression)
       :: ("ConsistentRead", sprint "%B" consistent)
       :: (match token with 
         | None -> []
         | Some t -> [ "NextToken", t ])) in 
    HC.try_bind
      (fun () ->
         let key_equals_value = Util.encode_key_equals_value ~safe:true params in
         let uri_query_component = String.concat "&" key_equals_value in
         HC.post ~body:(`String uri_query_component) url)
      (fun (header,body) ->
         let xml = X.xml_of_string body in
         HC.return (`Ok (select_of_xml encoded xml)))
      (function 
        | HC.Http_error (code, _, body) -> 
            HC.return (error_msg code body)
        | e -> raise e)
end
