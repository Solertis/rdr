#!/bin/bash
ocamlbuild.native -lib unix -lib str src/Rdr.native -- -h bin/other && mv Rdr.native rdr && cp rdr ~/bin/
# && ./graph.sh toc_call_graph.gv
