;;;
;;; Print the radio's own statistics whenever it reports them, like
;;; get-local-stats.py. The LFE twin of mte_local_stats.erl.
;;;
;;;   mte local-stats --lfe
;;;

(defmodule mtl_local_stats
  (export (run 1)))

(defun run (opts)
  (let ((c (mtc:connect opts)))
    (loop c (mtc:my_num c))))

(defun loop (c my-num)
  (case (mtc:next c 'infinity)
    ((tuple 'packet (= (map 'from from) p))
     (when (=:= from my-num))
     (case (mtc:get p '(decoded telemetry local_stats) 'undefined)
       ('undefined
        'ok)
       (stats
        (io:format "LOCAL STATS:~n")
        (lists:foreach
         (lambda (kv)
           (io:format "  ~-20s : ~ts~n"
                      (list (element 1 kv) (mtc:show (element 2 kv)))))
         (lists:sort (maps:to_list stats)))))
     (loop c my-num))
    ((tuple 'packet _other)
     (loop c my-num))
    ('closed
     (io:format "the radio closed the connection~n"))))
