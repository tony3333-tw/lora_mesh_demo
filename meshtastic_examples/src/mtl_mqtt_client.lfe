;;;
;;; A pretend node on MQTT, like MQTT/mqtt-client.py: publish a node
;;; info, a position and a text message, then print every packet on the
;;; channel's topic. The LFE twin of mte_mqtt_client.erl.
;;;
;;;   mte mqtt-client --lfe
;;;   mte mqtt-client --lfe --root msh/TW/2/e/ -m "hello"
;;;

(defmodule mtl_mqtt_client
  (export (run 1)))

(defun run (opts)
  (let* ((conn (mtq:connect opts))
         (bot (mtl_mqtt_send:bot opts "msh/US/Bots/2/e/"))
         (subscribe (++ (mtq:root opts "msh/US/Bots/2/e/")
                        (maps:get 'channel_name bot)
                        "/#")))
    (mtq:subscribe conn subscribe)
    (io:format "Subscribe Topic is: ~s~nPublish Topic is: ~s~n~n"
               (list subscribe (maps:get 'topic bot)))
    ;; send from another process: received packets print meanwhile
    (spawn_link (lambda () (mtl_mqtt_send:send-all conn bot)))
    (loop (maps:get 'key bot))))

(defun loop (key)
  (receive
    ((tuple 'publish (map 'payload payload))
     (case (mtq:open payload key)
       ((tuple 'ok (map 'packet packet))
        (io:format "~p~n~n" (list packet)))
       ((tuple 'error reason)
        (io:format "*** ServiceEnvelope: ~p~n" (list reason))))
     (loop key))
    ((tuple 'disconnected reason-code _props)
     (io:format "disconnected from the broker (~p)~n" (list reason-code)))))
