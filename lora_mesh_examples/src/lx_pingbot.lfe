;;;
;;; Answer "ping" on a channel, like serial_pingbot.py.
;;; The LFE twin of ex_pingbot.erl:
;;;
;;;   Bob on #0: ping?
;;;   me  on #0: @[Bob] Pong 🏓(Ridge, heard by field)
;;;
;;;   lme pingbot --lfe
;;;   lme pingbot --lfe --channel 1
;;;

(defmodule lx_pingbot
  (export (run 1)))

(defun run (opts)
  (let* ((channel (maps:get 'channel opts 0))
         (client (lmc:connect opts))
         (names (lmc:names (lmc:nodes client 500))))
    (lmc:subscribe client 'rx)
    (io:format "Listening for 'ping' on channel ~p (Ctrl-C to stop)...~n"
               (list channel))
    (loop client channel names)))

(defun loop (client channel names)
  (case (lmc:next client 'infinity)
    ((tuple 'rx rx)
     (handle client channel names rx)
     (loop client channel names))
    ((tuple 'node node)
     (loop client channel (lmc:add_name names node)))))

(defun handle (client channel names rx)
  (let ((text (maps:get #"text" rx))
        (sender (lmc:sender rx names)))
    (io:format "~ts~n" (list (lmc:describe rx names)))
    (if (andalso (lmc:is_channel rx)
                 (=:= (maps:get #"channel" rx) channel)
                 (ping? text))
      ;; #x1f3d3 is the table tennis emoji: lfec reads source files as
      ;; Latin-1, so a literal emoji in a string would be sent as 4 wrong
      ;; characters
      (let ((reply (unicode:characters_to_binary
                    (list "@[" sender "] Pong " #x1f3d3 (lmc:path_info rx)))))
        (io:format "Detected Ping. Replying on channel ~p with: ~ts~n"
                   (list channel reply))
        ;; answer on the mesh the ping came from
        (lmc:send client (map 'channel channel
                              'protocol (maps:get #"protocol" rx)
                              'text reply)))
      'ok)))

;; "ping", "Ping?", "PING!" ...; not our own "@[Bob] Pong" echoed back
(defun ping? (text)
  (andalso (=/= (string:find (string:lowercase text) "ping") 'nomatch)
           (=:= (string:prefix text "@[") 'nomatch)))
