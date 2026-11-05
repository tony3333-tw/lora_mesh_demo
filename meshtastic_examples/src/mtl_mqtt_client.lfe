;;;
;;; Both at once, like MQTT/mqtt-client.py: send a text (as mqtt-send),
;;; then print every text message lora_mesh publishes (as mqtt-receive).
;;; The LFE twin of mte_mqtt_client.erl. Ctrl-C ends.
;;;
;;;   mte mqtt-client --lfe -m "hello"
;;;

(defmodule mtl_mqtt_client
  (export (run 1)))

(defun run (opts)
  (let* ((conn (mtl_mqtt_receive:connect opts))
         (prefix (maps:get 'prefix opts "mesh"))
         (subscribe (++ prefix "/rx/#"))
         (publish (++ prefix "/tx")))
    (emqtt:subscribe conn (list_to_binary subscribe) 0)
    (io:format "Subscribe Topic is: ~s~nPublish Topic is: ~s~n~n"
               (list subscribe publish))
    (mtl_mqtt_send:send conn publish (mtl_mqtt_send:tx opts))
    (loop)))

(defun loop ()
  (receive
    ((tuple 'publish (map 'topic topic 'payload payload))
     (mtl_mqtt_receive:print topic payload)
     (loop))
    ((tuple 'disconnected reason-code _props)
     (io:format "disconnected from the broker (~p)~n" (list reason-code)))))
