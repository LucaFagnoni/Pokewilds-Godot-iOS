	db UNOWON_KING ; 025

	db  210,  190,  100,  120,  100,  30
	;   hp  atk  def  spd  sat  sdf

	db PSYCIC, DARK ; type
	db 1 ; catch rate
	db 200 ; base exp
	db NO_ITEM, BERRY ; items
	db GENDER_UNKOWN ; gender ratio
	db 100 ; unknown 1
	db 10 ; step cycles to hatch
	db 5 ; unknown 2
	INCBIN "gfx/pokemon/unown-king/front.dimensions"
	db 0, 0, 0, 0 ; padding
	db GROWTH_SLOW ; growth rate
	dn EGG_UNDISCOVERED, EGG_UNDISCOVERED ; egg groups

	; tm/hm learnset
	tmhm EARTHQUAKE, SURF, ANCIENTPOWER, DISABLE
	; end
