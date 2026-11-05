;;;
;;; Change one channel on the radio, like save-channel.py.
;;; The LFE twin of mte_save_channel.erl.
;;;
;;;   mte save-channel --lfe                    channel 1 = "NBC", default key
;;;   mte save-channel --lfe --index 2 --name farm --psk "base64 key"
;;;

(defmodule mtl_save_channel
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         (index (maps:get 'index opts 1))
         (old (maps:get 'settings (lists:nth (+ index 1) (mtc:channels c))))
         (settings (maps:merge
                    old
                    (map 'psk (mtq:psk (maps:get 'psk opts "AQ=="))
                         'name (unicode:characters_to_binary (maps:get 'name opts "NBC"))
                         'uplink_enabled 'true
                         'downlink_enabled 'true
                         'module_settings (map 'position_precision 13))))
         (role (if (=:= index 0) 'PRIMARY 'SECONDARY))
         (channel (map 'index index 'role role 'settings settings))
         (id (mtc:admin c (map 'set_channel channel))))
    (case (mtc:ack c id 10000)
      ('ok
       (io:format "Channel ~p saved:~n~p~n" (list index channel)))
      (other
       (io:format "The radio did not confirm: ~p~n" (list other))))
    (mtc:close c)))
