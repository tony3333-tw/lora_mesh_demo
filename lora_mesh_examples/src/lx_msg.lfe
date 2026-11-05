;;;
;;; Send one direct message to a contact by name, like serial_msg.py.
;;; The LFE twin of ex_msg.erl: lora_mesh 0.3 does not pass the radio's
;;; ACK on to MQTT, so this waits for an answer from the contact instead.
;;;
;;;   lme msg --lfe -d Alice -m "hello from LFE"
;;;

(defmodule lx_msg
  (export (run 1)))

(defun run (opts)
  (let* ((dest (maps:get 'dest opts "Alice"))
         (text (maps:get 'message opts "hello from LFE"))
         (wait (maps:get 'wait opts 10))
         (client (lmc:connect opts))
         (nodes (lmc:nodes client 1000)))
    (case (lmc:find nodes dest)
      ('error
       (io:format "Contact '~ts' not found. Available contacts:~n" (list dest))
       (lists:foreach
        (lambda (node)
          (case (maps:get #"long_name" node)
            ('null 'ok)
            (name (io:format "- ~ts (~ts)~n"
                             (list name (maps:get #"id" node))))))
        nodes))
      ((tuple 'ok node)
       (let ((id (maps:get #"id" node)))
         (io:format "Found contact: ~ts (~ts)~n"
                    (list (maps:get #"long_name" node) id))
         ;; listen first, so a fast answer is not missed
         (lmc:subscribe client 'rx)
         (io:format "Sending message: '~ts'~n" (list text))
         (lmc:send client (map 'to id 'text text))
         (wait-answer client id wait))))
    (lmc:disconnect client)))

(defun wait-answer
  ((_client _id 0)
   (io:format "Sent.~n"))
  ((client id seconds)
   (io:format "Sent, waiting ~p s for an answer...~n" (list seconds))
   (wait-loop client
              id
              (+ (erlang:monotonic_time 'millisecond) (* seconds 1000)))))

(defun wait-loop (client id deadline)
  (let ((left (max 0 (- deadline (erlang:monotonic_time 'millisecond)))))
    (case (lmc:next client left)
      ((tuple 'rx rx)
       (if (=:= (maps:get #"from" rx) id)
         (io:format "Answer: ~ts ~ts~n"
                    (list (maps:get #"text" rx) (lmc:path_info rx)))
         (wait-loop client id deadline)))
      ('timeout
       (io:format (++ "No answer (lora_mesh 0.3 does not report the radio's ACK; "
                      "the message may still have arrived)~n")))
      (_other
       (wait-loop client id deadline)))))
