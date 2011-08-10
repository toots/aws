module Client = 
  struct
    include Lwt
    include Lwt_io
    include Cohttp.Http_client
  end

module M = EC2_factory.Make (Client)

include M
