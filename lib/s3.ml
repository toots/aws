module Client =
  struct
    include Lwt
    include Lwt_io
    include Cohttp.Http_client
  end

module M = S3_factory.Make (Client)

include M
