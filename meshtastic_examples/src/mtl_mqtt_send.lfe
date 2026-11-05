;;;
;;; Send text messages by publishing to lora_mesh's mesh/tx, like
;;; MQTT/send-mqtt-packets.py. The LFE twin of mte_mqtt_send.erl:
;;; plain emqtt and json, without mtc.
;;;
;;;   mte mqtt-send --lfe                            "Hello from LFE" to everyone
;;;   mte mqtt-send --lfe -m "hello" -d '!0a0b0c0d'  a direct message
;;;

(defmodule mtl_mqtt_send
  (export (run 1)
          (tx 1)
          (send 3)))

(defun run (opts)
  (let ((conn (mtl_mqtt_receive:connect opts))
        (topic (++ (maps:get 'prefix opts "mesh") "/tx")))
    (io:format "Connected to server: ~s~n" (list (maps:get 'host opts "localhost")))
    (io:format "Publish Topic is: ~s~n~n" (list topic))
    (send conn topic (tx opts))
    (emqtt:disconnect conn)
    (io:format "Client Disconnected~n")))

;; The mesh/tx JSON: text, to (or protocol meshtastic: a broadcast to
;; the Meshtastic mesh), channel
(defun tx (opts)
  (let ((base (map #"text" (unicode:characters_to_binary
                            (maps:get 'message opts "Hello from LFE"))
                   #"channel" (maps:get 'channel opts 0))))
    (case (maps:find 'dest opts)
      ((tuple 'ok to)
       (maps:put #"to" (unicode:characters_to_binary to) base))
      ('error
       (maps:put #"protocol" #"meshtastic" base)))))

(defun send (conn topic tx)
  (let ((json (iolist_to_binary (json:encode tx))))
    (io:format "Sending ~ts~n" (list json))
    (let (((tuple 'ok _) (emqtt:publish conn
                                        (unicode:characters_to_binary topic)
                                        json
                                        1)))
      'ok)))
