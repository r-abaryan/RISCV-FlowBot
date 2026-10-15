#!/usr/bin/env python3
"""Classify one nextpnr-ecp5 run into exactly one outcome (M8C). Usage: pnr_classify.py <res_dir>
Reads <res_dir>/exit.txt, nextpnr.log, stdout.txt, report.json. Writes <res_dir>/result.txt (first line = class)
and result.json. Exit code: 0 TIMING_MET, 10 TIMING_FAILED, 20 ROUTING_FAILURE, 30 SETUP_FAILURE.
Classes (a green nextpnr exit under --timing-allow-fail is NOT timing closure):
  TIMING_MET       nextpnr exit 0, 'Routing complete'/'Router1 time'/'Router2 time' in log, report.json fmax achieved >= constraint for every clock
                   and at least one clock constrained.
  TIMING_FAILED    placement and routing completed but some clock achieved < constraint (or nextpnr exit != 0 only
                   because of timing).
  ROUTING_FAILURE  routing started ('Routing..') but 'Routing complete' absent / nextpnr died in the router.
  SETUP_FAILURE    anything before routing: missing inputs, LPF/JSON errors, placement failure, tool missing,
                   no report/log, no clock constraint found."""
import json, os, sys
d = sys.argv[1]
def rd(n):
    p = os.path.join(d, n)
    return open(p, errors="replace").read() if os.path.exists(p) else None
ex, log, so = rd("exit.txt"), rd("nextpnr.log"), rd("stdout.txt") or ""
text = (log or "") + so
info = {"nextpnr_exit": ex.strip() if ex else None}
def done(cls, why, code):
    info.update(cls=cls, reason=why)
    open(os.path.join(d, "result.txt"), "w").write(cls + "\n" + why + "\n")
    json.dump(info, open(os.path.join(d, "result.json"), "w"), indent=1)
    print(cls, "-", why); sys.exit(code)
if ex is None or log is None:
    done("SETUP_FAILURE", "nextpnr did not run or wrote no log/exit status", 30)
# router1 logs "Routing complete." + "Router1 time"; router2 logs "Router2 time" only after a legal, complete route.
routed = any(k in text for k in ("Routing complete", "Router1 time", "Router2 time"))
if not routed:
    if "Routing.." in text or "Running main router loop" in text:
        done("ROUTING_FAILURE", "router started but did not finish (no Router1/Router2 completion line) (exit %s)" % info["nextpnr_exit"], 20)
    done("SETUP_FAILURE", "failed before routing (exit %s); see nextpnr.log" % info["nextpnr_exit"], 30)
rep = rd("report.json")
if rep is None:
    done("SETUP_FAILURE", "routed but report.json missing; timing unknown", 30)
fmax = json.loads(rep).get("fmax", {})
info["fmax"] = fmax
if not fmax:
    done("SETUP_FAILURE", "no clock constraint/fmax in report.json", 30)
bad = {k: v for k, v in fmax.items() if v["achieved"] < v["constraint"]}
if bad or (info["nextpnr_exit"] != "0"):
    done("TIMING_FAILED", "routed; failing clocks: %s; exit %s" % (
        {k: "%.2f<%.2f MHz" % (v["achieved"], v["constraint"]) for k, v in bad.items()}, info["nextpnr_exit"]), 10)
done("TIMING_MET", "routed; " + ", ".join("%s %.2f>=%.2f MHz" % (k, v["achieved"], v["constraint"]) for k, v in fmax.items())
     + " (pre-bitstream STA estimate, no hardware)", 0)
