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

val without_colour: ('a -> 'b) -> 'a -> 'b

val ansi_format: ansi_format -> string -> string

val pp_ansi_format: ansi_format -> PPrint.document -> PPrint.document
