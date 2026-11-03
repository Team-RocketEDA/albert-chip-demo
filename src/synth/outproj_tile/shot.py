# shot.py — klayout batch GDS screenshot (run via run.sh in this dir).
# Loads the PDK tech + outproj_tile.gds, fits the top cell, exports PNG.
import os
import pya

here = os.path.dirname(os.path.abspath(__file__))
tech_file = os.path.join(os.environ["PDK"], "libs.tech", "klayout", "tech", "sky130A.lyt")

view = pya.Application.instance().main_window().create_view()
tech = pya.Technology.technology_from_xml(tech_file)
view.set_config("background-color", "#ffffff")
layout = view.load_layout(os.path.join(here, "outproj_tile.gds"), tech, 0)
view.max_hier()
view.zoom_fit()
view.save_image(os.path.join(here, "outproj_tile_top.png"), 1200, 900)
print("SHOT DONE")
