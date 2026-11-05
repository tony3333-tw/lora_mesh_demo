;;;
;;; Print everything lora_mesh publishes, like
;;; MQTT/receive-mqtt-packets.py. The LFE twin of mte_mqtt_receive.erl:
;;; plain emqtt and json, without mtc.
;;;
;;;   mte mqtt-receive --lfe                     mesh/rx/# and mesh/node/#
;;;   mte mqtt-receive --lfe --topic 'mesh/rx/#'
;;;

(defmodule mtl_mqtt_receive
  (export (run 1)
          (connect 1)
          (print 2)))

(defun run (opts)
  (let* ((prefix (maps:get 'prefix opts "mesh"))
         (topics (maps:get 'topics opts
                           (list (++ prefix "/rx/#")
                                 (++ prefix "/node/#"))))
         (conn (connect opts)))
    (io:format "Connected to MQTT broker!~n")
    (lists:foreach
     (lambda (topic)
       (emqtt:subscribe conn (unicode:characters_to_binary topic) 0)
       (io:format "Subscribed to topic: ~ts~n" (list topic)))
     topics)
    (loop)))

(defun loop ()
  (receive
    ((tuple 'publish (map 'topic topic 'payload payload 'retain retain))
     (print topic payload retain)
     (loop))
    ((tuple 'disconnected reason-code _props)
     (io:format "disconnected from the broker (~p)~n" (list reason-code)))))

;; the broker lora_mesh uses: --host (localhost) --port (1883)
;; --username --password. Raises (error (tuple 'mqtt_connect reason)).
(defun connect (opts)
  (application:ensure_all_started 'emqtt)
  (let* ((login (case opts
                  ((map 'username u 'password p)
                   (list (tuple 'username (unicode:characters_to_binary u))
                         (tuple 'password (unicode:characters_to_binary p))))
                  (_ ())))
         (args (list* (tuple 'host (maps:get 'host opts "localhost"))
                      (tuple 'port (maps:get 'port opts 1883))
                      (tuple 'clean_start 'true)
                      login))
         ((tuple 'ok conn) (emqtt:start_link args)))
    (unlink conn)
    (case (emqtt:connect conn)
      ((tuple 'ok _)
       (link conn)
       conn)
      ((tuple 'error reason)
       (catch (emqtt:stop conn))
       (error (tuple 'mqtt_connect reason))))))

;; one message: the topic, then its JSON indented
(defun print (topic payload)
  (print topic payload 'false))

(defun print
  ((topic #"" _retain)
   (io:format "~ts (removed)~n~n" (list topic)))
  ((topic payload retain)
   (let ((note (if retain " (retained)" ""))
         (body (try
                 (json:format (json:decode payload))
                 (catch
                   ((tuple _ _ _) payload)))))
     (io:format "~ts~s~n~ts~n~n" (list topic note body)))))
