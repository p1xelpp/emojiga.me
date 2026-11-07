from ursina.input_handler import bind

def enable_zqsd_controls():
    bind("z", "w")
    bind("q", "a")