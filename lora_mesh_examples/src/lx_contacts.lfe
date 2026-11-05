;;;
;;; Contacts: every node lora_mesh knows, like serial_contacts.py and
;;; tcp_mchome_contacts.py. The LFE twin of ex_contacts.erl.
;;;
;;;   lme contacts --lfe
;;;   lme contacts --lfe --all
;;;   lme contacts --lfe --json
;;;
;;; routes (lora_mesh 0.3.2): how each bridge's radio reaches the contact.
;;;

(defmodule lx_contacts
  (export (run 1)))

(defun run (opts)
  (let* ((client (lmc:connect opts))
         (all? (maps:get 'all opts 'false))
         (nodes (lists:filter
                 (lambda (node)
                   (orelse all?
                           (=:= (maps:get #"protocol" node) #"meshcore")))
                 (lmc:nodes client 1000))))
    (if (maps:get 'json opts 'false)
      (io:format "~ts~n" (list (json:format nodes)))
      (table nodes))
    (lmc:disconnect client)))

(defun table
  (('())
   (io:format "no nodes yet (is lora_mesh running and connected to the broker?)~n"))
  ((nodes)
   (io:format "~-15s ~-9s ~-14s ~-20s ~-10s ~-12s ~s~n"
              (list "id" "type" "name" "position" "heard" "heard by" "routes"))
   (lists:foreach (fun row 1) nodes)
   (io:format "~p nodes~n" (list (length nodes)))))

(defun row (node)
  (io:format "~-15ts ~-9ts ~-14ts ~-20s ~-10s ~-12ts ~ts~n"
             (list (maps:get #"id" node)
                   (lmc:kind node)
                   (name node)
                   (position (maps:get #"position" node 'null))
                   (ago (maps:get #"last_heard" node 'null))
                   (lists:join ","
                               (lists:sort
                                (maps:keys (maps:get #"heard_by" node #m()))))
                   (lmc:route_text node))))

(defun name (node)
  (case (maps:get #"long_name" node 'null)
    ('null #"?")
    (name name)))

(defun position
  (('null)
   "-")
  ((pos)
   (io_lib:format "~.4f,~.4f"
                  (list (float (maps:get #"latitude" pos))
                        (float (maps:get #"longitude" pos))))))

(defun ago
  (('null)
   "-")
  ((time)
   (let ((s (- (erlang:system_time 'second) time)))
     (cond
      ((< s 120) (io_lib:format "~ps ago" (list s)))
      ((< s 7200) (io_lib:format "~pm ago" (list (div s 60))))
      ((< s 172800) (io_lib:format "~ph ago" (list (div s 3600))))
      ;; long ago: just the date
      ('true (string:slice (calendar:system_time_to_rfc3339 time) 0 10))))))
