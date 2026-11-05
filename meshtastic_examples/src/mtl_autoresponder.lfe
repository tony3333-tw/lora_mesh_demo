;;;
;;; Answer every text message, like autoresponder.py ("Message Received"
;;; to everyone on channel 0); -c 1 answers on channel 1, like
;;; send-secondary.py. The LFE twin of mte_autoresponder.erl.
;;;
;;;   mte autoresponder --lfe
;;;   mte autoresponder --lfe -c 1 -m "got it"
;;;
;;; It does not answer its own reply text.
;;;

(defmodule mtl_autoresponder
  (export (run 1)))

(defun run (opts)
  (let ((c (mtc:connect opts))
        (reply (unicode:characters_to_binary
                (maps:get 'message opts "Message Received")))
        (channel (maps:get 'channel opts 0)))
    (io:format "Answering every text message with \"~ts\" on channel ~p. Ctrl-C ends.~n"
               (list reply channel))
    (loop c reply channel)))

(defun loop (c reply channel)
  (case (mtc:next c 'infinity)
    ((tuple 'packet (map 'decoded (map 'portnum 'TEXT_MESSAGE_APP 'text text)))
     (when (=/= text reply))
     (io:format "Received: ~ts~n" (list text))
     (mtc:send_text c reply (map 'channel channel))
     (io:format "Sent: ~ts~n" (list reply))
     (loop c reply channel))
    ((tuple 'packet _other)
     (loop c reply channel))
    ('closed
     (io:format "the radio closed the connection~n"))))
