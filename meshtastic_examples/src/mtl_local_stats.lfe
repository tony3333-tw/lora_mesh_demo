;;;
;;; Print each bridge's radio statistics whenever the radio reports
;;; them, like get-local-stats.py. The LFE twin of mte_local_stats.erl
;;; (lora_mesh 0.4: mesh/packet/<my id>).
;;;
;;;   mte local-stats --lfe
;;;

(defmodule mtl_local_stats
  (export (run 1)))

(defun run (opts)
  (let* ((c (mtc:connect opts))
         ;; each bridge's radio: #"!0600d1e5" => #"home"
         (mine (maps:from_list
                (lists:map
                 (lambda (b)
                   (tuple (maps:get #"my_id" b)
                          (maps:get #"bridge" b)))
                 (mtc:bridges c opts)))))
    (if (=:= (map_size mine) 0)
      (io:format "no Meshtastic bridge has reported its radio yet (lora_mesh 0.4 needed)~n")
      (io:format "Waiting for local stats from ~ts. Ctrl-C ends.~n"
                 (list (lists:join ", " (lists:sort (maps:values mine))))))
    (mtc:subscribe c 'packets)
    (loop c mine)))

(defun loop (c mine)
  (case (mtc:next c 'infinity)
    ((tuple 'packet p)
     (let ((from (maps:get #"from_id" p #"")))
       (case (maps:find from mine)
         ((tuple 'ok bridge)
          (print-stats bridge p))
         ('error
          'ok)))
     (loop c mine))
    (_other
     (loop c mine))))

(defun print-stats (bridge p)
  (case (mtc:get p (list #"decoded" #"telemetry" #"local_stats") 'undefined)
    ('undefined
     'ok)
    (stats
     (io:format "LOCAL STATS (~ts):~n" (list bridge))
     (lists:foreach
      (lambda (kv)
        (io:format "  ~-22ts : ~ts~n"
                   (list (element 1 kv)
                         (mtc:show (element 2 kv)))))
      (lists:sort (maps:to_list stats))))))
