;;;
;;; Fox hunt: keep asking one node for telemetry and print the SNR and
;;; RSSI of each answer, like foxhunt.py and test-rssi-snr.py.
;;; The LFE twin of mte_foxhunt.erl.
;;;
;;;   mte foxhunt --lfe -d "Barn sensor"
;;;   mte foxhunt --lfe -d '!2a2a2a2a' --pause 5 --wait 15
;;;

(defmodule mtl_foxhunt
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (fox (mtc:dest c opts))
         (pause (* (maps:get 'pause opts 2) 1000))
         (wait (maps:get 'wait opts 10)))
    (io:format "Hunting ~ts. Ctrl-C ends.~n" (list (mtc:name c fox)))
    (ask c fox)
    (loop c fox pause wait (mtc:deadline (* wait 1000)))))

;; telemetry with battery_level 69, as in the Python examples
(defun ask (c fox)
  (io:format "Requesting data...~n")
  (mtc:send_data c 'TELEMETRY_APP
                 (tuple 'telemetry (map 'device_metrics (map 'battery_level 69)))
                 (map 'to fox 'want_response 'true)))

(defun loop (c fox pause wait deadline)
  (case (mtc:next c (mtc:left deadline))
    ((tuple 'packet (= (map 'from from) p))
     (when (=:= from fox))
     (io:format "~nSNR: ~p RSSI: ~p~n~n"
                (list (maps:get 'rx_snr p 0.0) (maps:get 'rx_rssi p 0)))
     (timer:sleep pause)
     (ask c fox)
     (loop c fox pause wait (mtc:deadline (* wait 1000))))
    ((tuple 'packet _other)
     (loop c fox pause wait deadline))
    ('timeout
     (io:format "No response received for ~p seconds, retrying...~n" (list wait))
     (ask c fox)
     (loop c fox pause wait (mtc:deadline (* wait 1000))))
    ('closed
     (io:format "the radio closed the connection~n"))))
