# shot.py — klayout batch GDS screenshot (run via run.sh; OUT/TILE/TAG env).
# Loads the PDK tech + <tile>_<tag>.gds, fits the top cell, exports PNG.
import os
import pya

out = os.environ["OUT"]
tile = os.environ["TILE"]
tag = os.environ["TAG"]
tech_file = os.path.join(os.environ["PDK"], "libs.tech", "klayout", "tech", "sky130A.lyt")

view = pya.Application.instance().main_window().create_view()
tech = pya.Technology.technology_from_xml(tech_file)
view.set_config("background-color", "#ffffff")
layout = view.load_layout(os.path.join(out, f"{tile}_{tag}.gds"), tech, 0)
view.max_hier()
view.zoom_fit()
view.save_image(os.path.join(out, f"{tile}_{tag}_top.png"), 1200, 900)
print("SHOT DONE")
