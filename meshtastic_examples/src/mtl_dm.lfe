;;;
;;; Send one direct message, like send-direct-message.py. The LFE twin
;;; of mte_dm.erl: lora_mesh 0.3 does not pass the radio's ACK on to
;;; MQTT, so this prints what that node sends back for --wait seconds.
;;;
;;;   mte dm --lfe -d "Hill top" -m "Test Message"
;;;

(defmodule mtl_dm
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (nodes (mtc:nodes c opts))
         (dest (mtc:dest c opts))
         (name (mtc:name (mtc:names nodes) dest))
         (text (maps:get 'message opts "Test Message"))
         (wait (maps:get 'wait opts 10)))
    ;; listen first, so a fast answer is not missed
    (mtc:subscribe c 'rx)
    (mtc:send_text c text (map 'to dest))
    (io:format "Sent \"~ts\" to ~ts, waiting ~p s for an answer...~n"
               (list text name wait))
    (case (answers c dest name (mtc:deadline (* wait 1000)) 0)
      (0 (io:format (++ "No answer (lora_mesh 0.3 does not report the ACK; "
                        "the message may still have arrived)~n")))
      (_ 'ok))
    (mtc:disconnect c)))

(defun answers (c dest name deadline count)
  (case (mtc:next c (mtc:left deadline))
    ((tuple 'rx (map #"from" from #"text" text))
     (when (=:= from dest))
     (io:format "~ts: ~ts~n" (list name text))
     (answers c dest name deadline (+ count 1)))
    ('timeout
     count)
    (_other
     (answers c dest name deadline count))))
