;;;
;;; Print every packet published to a Meshtastic MQTT broker, decrypted
;;; with the channel key, like MQTT/receive-mqtt-packets.py.
;;; The LFE twin of mte_mqtt_receive.erl.
;;;
;;;   mte mqtt-receive --lfe                        mqtt.meshtastic.org, msh/US/2/e/
;;;   mte mqtt-receive --lfe --root msh/TW/2/e/
;;;   mte mqtt-receive --lfe --channel-name farm --key BASE64KEY
;;;

(defmodule mtl_mqtt_receive
  (export (run 1)))

(defun run (opts)
  (let* ((key (mtq:key (maps:get 'key opts "AQ==")))
         (root (mtq:root opts "msh/US/2/e/"))
         (topics (maps:get 'topics opts
                           (list (++ root "PKI/#")
                                 (++ root (maps:get 'channel_name opts "LongFast") "/#"))))
         (conn (mtq:connect opts)))
    (io:format "Connected to MQTT broker!~n")
    (lists:foreach
     (lambda (topic)
       (mtq:subscribe conn topic)
       (io:format "Subscribed to topic: ~ts~n" (list topic)))
     topics)
    (loop key)))

(defun loop (key)
  (receive
    ((tuple 'publish (map 'topic topic 'payload payload))
     (case (mtq:open payload key)
       ((tuple 'ok envelope)
        (case (maps:find 'gateway_id envelope)
          ((tuple 'ok gateway) (io:format "Gateway ID: ~ts~n" (list gateway)))
          ('error 'ok))
        (let ((packet (maps:get 'packet envelope)))
          (if (maps:get 'decrypt_failed packet 'false)
            (io:format "Decryption failed; retaining original encrypted payload~n"))
          (io:format "~p~n~n" (list packet))))
       ((tuple 'error _)
        (io:format "~ts: not a ServiceEnvelope (~p bytes)~n~n"
                   (list topic (byte_size payload)))))
     (loop key))
    ((tuple 'disconnected reason-code _props)
     (io:format "disconnected from the broker (~p)~n" (list reason-code)))))
