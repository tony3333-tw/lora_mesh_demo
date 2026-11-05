;;;
;;; Decode protobuf bytes, like decode-protobuf.py (a Telemetry message).
;;; The LFE twin of mte_decode.erl.
;;;
;;;   mte decode --lfe                          the bytes from decode-protobuf.py
;;;   mte decode --lfe --hex 0d9a2b4467...
;;;   mte decode --lfe --base64 DciHAA8VkD90SBjECA== --type position
;;;

(defmodule mtl_decode
  (export (run 1)))

;; b"\r\232+Dg\032\n\r\341z \301\025\000\200\241B" in decode-protobuf.py
(defun sample ()
  (binary 13 154 43 68 103 26 10 13 225 122 32 193 21 0 128 161 66))

(defun run (opts)
  (let* ((bytes (case opts
                  ((map 'hex hex) (binary:decode_hex (list_to_binary hex)))
                  ((map 'base64 b64) (base64:decode b64))
                  (_ (sample))))
         (type (list_to_atom (maps:get 'type opts "telemetry")))
         (decoded (mtc:decode bytes type)))
    (io:format "~p~n" (list (mtc:compact decoded type)))))
