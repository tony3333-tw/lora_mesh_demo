;;;
;;; Send one direct message and wait for its ACK, like
;;; send-direct-message.py. Then print what that node sends us for
;;; --wait seconds (10). The LFE twin of mte_dm.erl.
;;;
;;;   mte dm --lfe -d "Hill top" -m "Test Message"
;;;

(defmodule mtl_dm
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (dest (mtc:dest c opts))
         (text (maps:get 'message opts "Test Message"))
         (id (mtc:send_text c text (map 'to dest
                                        'want_ack 'true
                                        'want_response 'true))))
    (io:format "Sent \"~ts\" to ~ts, waiting for the ACK...~n"
               (list text (mtc:name c dest)))
    (case (mtc:ack c id 60000)
      ('ok
       (io:format "ACK: ~ts has it~n" (list (mtc:name c dest))))
      ((tuple 'error reason)
       (io:format "NAK: ~s~n" (list reason)))
      ('timeout
       (io:format "no ACK within 60 s~n"))
      ('closed
       (io:format "the radio closed the connection~n")))
    (answers c dest (mtc:deadline (* (maps:get 'wait opts 10) 1000)))
    (mtc:close c)))

(defun answers (c dest deadline)
  (case (mtc:next c (mtc:left deadline))
    ((tuple 'packet (map 'from from
                         'decoded (map 'portnum 'TEXT_MESSAGE_APP 'text text)))
     (when (=:= from dest))
     (io:format "~ts: ~ts~n" (list (mtc:name c dest) text))
     (answers c dest deadline))
    ((tuple 'packet _other)
     (answers c dest deadline))
    (_timeout-or-closed
     'ok)))
