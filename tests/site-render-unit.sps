#!r6rs
;;; The docs site's whole pipeline, (site render), on small inputs: markdown
;;; through chez-cmark-gfm, headings slugged, links rewritten across pages,
;;; each page templated.  Imports (cmark gfm), which loads libcmark-gfm.  Not
;;; named test-*.sps, so `make test` does not run it; `make check-site` does.
;;; From the repository root:
;;;   CHEZSCHEMELIBDIRS=.:tests:build/scheme-libs:vendor/chez-cmark-gfm/src \
;;;     chez --program tests/site-render-unit.sps
(import (rnrs) (srfi :64) (testing) (site render) (site serializer))

;; string-contains-sub? : String String -> Boolean
(define (string-contains-sub? hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? needle (substring hay i (+ i n))) #t)
            (else (loop (+ i 1)))))))

;; count-substring : String String -> Integer
;; Non-overlapping occurrences of NEEDLE in HAY.
(define (count-substring hay needle)
  (let ((h (string-length hay)) (n (string-length needle)))
    (let loop ((i 0) (count 0))
      (cond ((> (+ i n) h) count)
            ((string=? needle (substring hay i (+ i n))) (loop (+ i n) (+ count 1)))
            (else (loop (+ i 1) count))))))

;; page-html : SiteResult String -> String
(define (page-html r name)
  (sxml->html (cond ((assoc name (site-result-pages r)) => cdr)
                    (else (error 'site-render-unit "page missing" name)))))

;; Two pages; the home page links to a heading on handlers.md, and handlers.md
;; links back to the home page.  The anchor is only knowable after handlers.md
;; is slugged.
(define inputs
  '(("README.md" . "# Home\n\nSee [reading](handlers.md#reading-a-request).\n")
    ("handlers.md" . "# Handlers\n\n## Reading a request\n\ntext\n\n### The path\n\nmore text\n\n[home](README.md)\n")))

(define r (render-site inputs "main"))

(run-suite "site-render-unit"
  (lambda ()
    (test-equal "every input yields a page, in input order"
      '("README.md" "handlers.md") (map car (site-result-pages r)))
    (test-equal "the registry carries every one of a page's heading slugs, its h1 included"
      '("handlers" "reading-a-request" "the-path")
      (cond ((assoc "handlers.md" (site-result-registry r)) => cdr) (else 'missing)))
    (test-equal "resolvable cross-page links, README.md among them, do not dangle"
      '() (site-result-leaked r))

    (let ((html (page-html r "handlers.md")))
      (test-eq "the rail links the h2 anchor" 'linked
        (if (string-contains-sub? html "href=\"#reading-a-request\"") 'linked 'missing))
      (test-eq "the rail does not link the h1 anchor" 'absent
        (if (string-contains-sub? html "href=\"#handlers\"") 'present 'absent))
      (test-eq "an h3 remains a rendered link target" 'present
        (if (string-contains-sub? html "id=\"the-path\"") 'present 'missing))
      (test-eq "the rail lists h2 sections, not h3 details" 'absent
        (if (string-contains-sub? html "href=\"#the-path\"") 'present 'absent))
      (test-eqv "a link to README.md is written as index.html, beside the wordmark's"
        2 (count-substring html "href=\"index.html\""))
      (test-eq "no link keeps the README.md name" 'absent
        (if (string-contains-sub? html "README") 'present 'absent))
      (test-eq "the page's title is its nav label" 'present
        (if (string-contains-sub? html "<title>Handlers</title>") 'present 'missing)))

    ;; The home page is reached from the wordmark and the page text, not
    ;; listed as a nav item: only the wordmark links index.html on a page that
    ;; does not link it in its text.
    (let ((html (page-html r "README.md")))
      (test-eqv "index.html is linked once on the home page: the wordmark, not a nav item"
        1 (count-substring html "href=\"index.html\""))
      (test-eq "the home page has no footer nav" 'absent
        (if (string-contains-sub? html "class=\"pagenav\"") 'present 'absent)))

    ;; A page in the nav order gets its neighbours as footer links.
    (let ((html (page-html (render-site '(("installing.md" . "# Installing\n")
                                          ("quickstart.md" . "# Quickstart\n")
                                          ("examples.md" . "# Examples\n"))
                                        "main")
                           "quickstart.md")))
      (test-equal "a middle page links its previous and next pages"
        '(#t #t)
        (list (string-contains-sub?
               html "<a href=\"installing.html\"><span class=\"lbl\">Previous")
              (string-contains-sub? html "<a href=\"examples.html\" class=\"next\">"))))

    ;; A warning-led blockquote passes through the whole pipeline as a callout.
    (let ((html (page-html (render-site '(("handlers.md" . "> ⚠️ Answer quickly.\n")) "main")
                           "handlers.md")))
      (test-eq "a warning blockquote is rendered inside a callout div" 'present
        (if (string-contains-sub? html "<div class=\"callout warning\"><blockquote>")
            'present 'missing)))

    (test-equal "an unresolvable cross-page anchor is reported"
      '(("README.md" . "handlers.md#gone"))
      (site-result-leaked
       (render-site '(("README.md" . "[x](handlers.md#gone)\n")
                      ("handlers.md" . "# Handlers\n"))
                    "main")))
    (test-equal "an unresolvable README.md anchor is reported"
      '(("handlers.md" . "README.md#gone"))
      (site-result-leaked
       (render-site '(("README.md" . "# Home\n")
                      ("handlers.md" . "[x](README.md#gone)\n"))
                    "main")))
    (test-equal "danglers across pages come back in page order"
      '(("README.md" . "#a") ("handlers.md" . "#b"))
      (site-result-leaked
       (render-site '(("README.md" . "[x](#a)\n") ("handlers.md" . "[y](#b)\n"))
                    "main")))))
