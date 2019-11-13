type ansi_style =
  | Black
  | Red
  | Green
  | Yellow
  | Blue
  | Magenta
  | Cyan
  | White
  | Bold
  | Underline
  | Blinking
  | Inverted


type ansi_format = ansi_style list

val do_colour: bool ref

val ansi_format: ?err:bool -> ansi_format -> string -> string

val pp_ansi_format: ?err:bool -> ansi_format -> PPrint.document -> PPrint.document
