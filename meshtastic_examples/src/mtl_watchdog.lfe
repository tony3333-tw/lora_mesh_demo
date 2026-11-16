;;;
;;; Watch lora_mesh and its bridges, like tcp_watchdog.py watches one
;;; radio. The LFE twin of mte_watchdog.erl (lora_mesh 0.4:
;;; mesh/status, mesh/bridge/<id>/status).
;;;
;;;   mte watchdog --lfe
;;;   mte watchdog --lfe --every 60
;;;

(defmodule mtl_watchdog
  (export (run 1)))

(defun retry-ms () 3000)

(defun run (opts)
  ;; the broker connection is linked to us: survive it going down
  (process_flag 'trap_exit 'true)
  (let ((every (* (maps:get 'every opts 10) 1000)))
    (loop (connect opts) opts every (mtc:deadline every) (map))))

(defun connect (opts)
  (try
    (let ((c (mtc:connect opts)))
      (mtc:subscribe c 'status)
      (mtc:subscribe c 'bridges)
      (mtc:subscribe c 'rx)
      (io:format "Interface initialized.~n")
      c)
    (catch
      ((tuple 'error (tuple 'mqtt_connect reason) _)
       (io:format "Failed to initialize interface: ~p~n" (list reason))
       'undefined))))

;; no broker: try again after a while
(defun loop
  (('undefined opts every _check _seen)
   (io:format "Retrying connection to the interface...~n")
   (timer:sleep (retry-ms))
   (loop (connect opts) opts every (mtc:deadline every) (map)))
  ((c opts every check seen)
   (receive
     ((tuple 'publish msg)
      (loop c opts every check (event (mtc:decode c msg) seen)))
     ((tuple 'EXIT _conn reason)
      (io:format "Error with the interface (~p), reconnecting~n" (list reason))
      (loop 'undefined opts every check seen))
     ((tuple 'disconnected _code _props)
      (loop c opts every check seen))
     (after (mtc:left check)
       (io:format "Checking interface connection...~n")
       (summary seen)
       (loop c opts every (mtc:deadline every) seen)))))

;; seen: #"lora_mesh" => true | false, bridge => true | false
(defun event
  (((tuple 'status (map #"online" online)) seen)
   (changed #"lora_mesh" online seen "lora_mesh is ~s~n" (list (up online))))
  (((tuple 'bridge_status bridge s) seen)
   (case (maps:find #"connected" s)
     ((tuple 'ok connected)
      (when (is_map_key #"lora_mesh" seen)
            (=:= (map_get #"lora_mesh" seen) 'false))
      ;; lora_mesh is down: this is its last status, out of date
      (maps:put bridge connected seen))
     ((tuple 'ok connected)
      (changed bridge
               connected
               seen
               "bridge ~ts (~ts) is ~s~ts~n"
               (list bridge
                     (maps:get #"address" s #"?")
                     (up-down connected)
                     (why connected s))))
     ('error
      seen)))
  (((tuple 'rx rx) seen)
   (io:format "~ts: ~ts~n"
              (list (maps:get #"from" rx)
                    (maps:get #"text" rx)))
   seen)
  ((_other seen)
   seen))

(defun why (connected s)
  (case (maps:find #"reason" s)
    ((tuple 'ok r) (when (not connected))
     (list " (" r ")"))
    (_ "")))

(defun changed (key value seen format args)
  (case (maps:find key seen)
    ((tuple 'ok v) (when (=:= v value))
     'ok)
    (_
     (io:format format args)))
  (maps:put key value seen))

;; while lora_mesh is down, its bridges' last status is out of date
(defun summary (seen)
  (let ((up (maps:get #"lora_mesh" seen 'undefined)))
    (case up
      ('true (io:format "lora_mesh is up.~n"))
      ('false (io:format "lora_mesh is DOWN.~n"))
      ('undefined (io:format "lora_mesh has not said (lora_mesh 0.4 needed).~n")))
    (lists:foreach
     (lambda (kv)
       (io:format "  ~ts: ~s~n"
                  (list (element 1 kv)
                        (if (=:= up 'false)
                          "unknown (lora_mesh is down)"
                          (up-down (element 2 kv))))))
     (lists:sort (maps:to_list (maps:remove #"lora_mesh" seen))))))

(defun up
  (('true) "up")
  (('false) "DOWN"))

(defun up-down
  (('true) "connected")
  (('false) "DISCONNECTED"))
