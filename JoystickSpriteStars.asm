Mode			equ &bc0e
CLS			equ &bc14
PrintChar		equ &bb5a
WaitChar		equ &bb06
Ink			equ &bc32 ;(a,b,c)
Border			equ &bc38 ;(b,c)
Pen			equ &bb90 ;(in: A=foreground color 0..15)
Fill			equ &bc44 
TextCursor		equ &bb75 ;(h=x,l=y,a=rollcount)
MoveCursor		equ &bb8a ;(h=x,l=y)
ScrNextLine 		equ &BC26 ;out: HL=HL+800h, or HL=HL+50h-3800h (or so)
ScrDotPosition 		equ &BC1D ;in: DE=x, HL=y, out: HL=vram addr, C=mask, DE, B
WaitFlyback		equ &BD19 ;wait until/unless PIO.Port B bit0=1 (vsync)
ReadKey	 		equ &bb1b
Linefrom		equ &bbf6  ;in: de=x, hl=y  ;\draw line from current coordinate
LineTo 			equ &bbf9  ;in: de=x, hl=y  ;/to specified target coordinate
SetOrigin	 	equ &bbc9  ;in: de=x, hl=y (also does MOVE 0,0)
GrPen			equ &bbde  ;in; a=ink color 
GRA_LINE_ABSOLUTE 	equ &BBF6
SCR_HORIZONTAL    	equ &BC5F ;in: A=pen, DE=x1, BC=x2, HL=y

Black 			equ 0
Blue			equ 1
BrightBlue		equ 2
Red			equ 3
Magenta			equ 4
Mauve			equ 5
BrightRed		equ 6
Purple			equ 7
BrightMagenta		equ 8
Green			equ 9
Cyan			equ 10
SkyBlue			equ 11
Yellow			equ 12
White			equ 13
PastelBlue		equ 14
Orange			equ 15
Pink			equ 16
PastelMagenta		equ 17
BrightGreen		equ 18
SeaGreen		equ 19
BrightCyan		equ 20
Lime			equ 21
PastelGreen		equ 22
PastelCyan		equ 23
BrightYellow		equ 24
PastelYellow		equ 25
BrightWhite		equ 26

	org &4000			;Start of our program
	run &4000
;Setup
SetMode:
	ld a,0	; mode 0
	call Mode
	;ret
	
SetInks:
	;; setup inks 
	ld b,Black
	ld c,Black
	call Border
	ld a,0 		; background
	ld b,Black 	; black
	ld c,Black 
	call Ink
	ld a,1 		; text (ink 1)
	ld b,White
	ld c,White 
	ld a,2 		; flash text (ink 2)
	ld b,BrightRed
	ld c,BrightYellow 
	call Ink
	ld a,3 
	ld b,Black
	ld c,Black
	call Ink
	;; ship inks
	call Ink
	ld a,15 	; main body (ink 15)
	ld b,BrightWhite
	ld c,BrightWhite 
	call Ink
	ld a,14 	; stripe (ink 14)
	ld b,BrightRed
	ld c,BrightRed
	call Ink
	ld a,10 	; canopy (ink 10)
	ld b,PastelBlue
	ld c,PastelBlue
	call Ink
	ld a,4 		; outline (ink 4)
	ld b,White
	ld c,White
	call Ink
	ld a,8 		; tail flash (ink 8)
	ld b,BrightRed
	ld c,Orange 
	call Ink
	;ret

Text:
	ld h,3 
	ld l,3
	call TextCursor
	ld a,1
	call Pen
	ld hl,Message
	call PrintString

	
drawline:
	push hl
	push de
		ld a,15
		call GrPen 
		ld hl,334
		ld de,0
		call SetOrigin
		call LineFrom
		ld hl,0
		ld de,640
		call LineTo
		ld a,1
		call GrPen
	pop de
	pop hl	

main:
	ld a,0				;Force Draw of character first run
	JR StartDraw
infloop:
     call DrawStars	
	call check_keys
	call &bb24 			; KM Get Joystick... Returns ---FRLDU
	or a
	call WaitFlyback
	jr z,infloop		;See if no keys are pressed
StartDraw:
	push af
		ld de,(PlayerX)	;Back up X
		ld (PlayerX2),de
		ld hl,(PlayerY)	;Back up Y
		ld (PlayerY2),hl
		
		push hl
		push de
			call BlankPlayer ;Remove old player sprite
		pop de
		pop hl
	pop af
JoyNot:
	bit 0,A
	jr z,JoyNotUp		;Jump if UP not presesd
	inc hl				;Move Y Up the screen
	inc hl				;Move Y Up the screen
JoyNotUp:
	bit 1,A
	jr z,JoyNotDown		;Jump if DOWN not presesd
	dec hl				;Move Y Down the screen
	dec hl				;Move Y Down the screen
JoyNotDown:
	bit 2,A
	jr z,JoyNotLeft 	;Jump if LEFT not presesd
	dec de				;Move X Left 
	dec de				;Move X Left 
JoyNotLeft:
	bit 3,A
	jr z,JoyNotRight	;Jump if RIGHT not presesd
	inc de				;Move X Right
	inc de				;Move X Right
JoyNotRight: 
	bit 4,A
	jr z,JoyNotFire
	push hl
	push de
	;push bc
		
		ld a,2
		call GrPen
		ld de,0
		ld bc,(PlayerX2)

		ld hl,(PlayerY2) 
		dec hl 
		dec hl
		dec hl
		dec hl
		call SCR_HORIZONTAL ;in: A=pen, DE=x1, BC=x2, HL=y
		
		ld a,0
		call GrPen
		ld de,0
		ld bc,(PlayerX2)

		ld hl,(PlayerY2) 
		dec hl
		dec hl
		dec hl
		dec hl
		call SCR_HORIZONTAL ;in: A=pen, DE=x1, BC=x2, HL=y
	;pop bc
	pop de
	pop hl	
	
JoyNotFire2:
	bit 5,A
	jr z,JoyNotFire
	push de
	push hl
		ld a,1
	pop hl
	pop de
JoyNotFire:	
	ld (PlayerX),de		;Update X
	ld (PlayerY),hl		;Update Y

	
CheckX:
	;X Boundary Check 
	ld a,d	
	cp 1				
	;jr c,PlayerPosXOk
	ld a,e
	cp 146	
	jr c,PlayerPosXOk
	jr PlayerReset		;Player out of bounds - Reset!
PlayerPosXOk:

	;Y Boundary Check - only need to check 1 byte
	ld a,l
	cp 8				;Player 8 lines tall
	jr c,PlayerReset
	cp 167
	jr c,PlayerPosYOk	;Not Out of bounds
	
PlayerReset:
	ld de,(PlayerX2) 	;Reset Xpos	
	ld (PlayerX),de	

	ld hl,(PlayerY2)	;Reset Ypos
	ld (PlayerY),hl
	
PlayerPosYOk:
	call DrawPlayer		;Draw Player Sprite
	;;ld bc,10
	;;call PauseBC		;Wait a bit!

	jp infloop

PauseBC:
	dec bc
	ld a,b
	or c
	jr nz,PauseBC
	ret


BlankPlayer:
	ld bc,blankSprite	;Blank Sprite source
	jr DrawPlayerSprite
DrawPlayer:
	ld bc,SpriteShip	;Player Sprite Source
DrawPlayerSprite:
	push bc
		call ScrDotPosition	;Scr Dot Position - Returns address in HL
	pop de
	ld b,8				;Lines
SpriteNextLine:
	push hl
		ld c,8				;Bytes per line (Width)
SpriteShipNextByte:
		ld a,(de)			;Source Byte
		ld (hl),a			;Screen Destination

		inc de				;INC Source (Sprite) Address
		inc hl				;INC Dest (Screen) Address

		dec c 				;Repeat for next byte
		jr nz,SpriteShipNextByte
	
		;ld a,(de)		;Source Byte
		
		;ld (hl),a		;Screen Destination
		;inc de			;INC Source (Sprite) Address
		;inc hl			;INC Dest (Screen) Address
		;ld a,(de)		;Source Byte
		;ld (hl),a		;Screen Destination
		;inc de			;INC Source (Sprite) Address
		;inc hl			;INC Dest (Screen) Address
	pop hl
	call ScrNextLine		;Scr Next Line (Alter HL to move down a line)
	djnz SpriteNextLine	;Repeat for next line
	ret					;Finished 



SpriteShipflip:
	   DB      &75,&FF,&AA,&00,&00,&00,&00,&00
        DB      &10,&FF,&FF,&00,&00,&00,&00,&00
        DB      &00,&75,&FF,&FF,&00,&0F,&0A,&00
        DB      &00,&75,&FF,&FF,&FF,&FF,&0F,&00
        DB      &17,&3F,&3F,&3F,&3F,&7F,&FF,&FF
        DB      &17,&3F,&3F,&3F,&3F,&FF,&FF,&AA
        DB      &00,&FF,&FF,&FF,&FF,&FF,&30,&00
        DB      &00,&00,&30,&30,&30,&30,&00,&00

SpriteShip:
	   DB      &00,&00,&00,&00,&00,&55,&FF,&BA
        DB      &00,&00,&00,&00,&00,&FF,&FF,&20
        DB      &00,&05,&0F,&00,&FF,&FF,&BA,&00
        DB      &00,&0F,&FF,&FF,&FF,&FF,&BA,&00
        DB      &FF,&FF,&BF,&3F,&3F,&3F,&3F,&2B
        DB      &55,&FF,&FF,&3F,&3F,&3F,&3F,&2B
        DB      &00,&30,&FF,&FF,&FF,&FF,&FF,&00
        DB      &00,&00,&30,&30,&30,&30,&00,&00

        
SpriteAlienRed:
        DB      &00,&3F,&2A,&00
        DB      &15,&3F,&3F,&00
        DB      &7B,&B7,&F3,&2A
        DB      &3F,&B7,&B7,&2A
        DB      &15,&3F,&3F,&00
        DB      &15,&2B,&3F,&00
        DB      &3F,&15,&15,&2A
        DB      &2A,&15,&00,&2A

blankSprite:
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	DB      &00,&00,&00,&00,&00,&00,&00,&00
	

;Current player pos
PlayerX: dw &86
PlayerY: dw &64

;Last player pos (For clearing sprite)
PlayerX2: dw &10
PlayerY2: dw &10

check_keys:
;; test if any key has been pressed
call ReadKey
ret nc
;; A = code of the key that has been pressed
;;
;; check the codes we are using and handle appropiatly.
cp '1'				; show message
jp z,keyTEXT
cp '1'				; show message
jp z,keyTEXT
ret

Locate:
		push hl
				inc h
				inc l
				call TextCursor 
		pop hl
		ret

NewLine:
		ld a,13 			; carrage return
		call PrintChar
		ld a,10				; line feed
		jp PrintChar
		ret

PrintString:
		ld a,(hl)			; print '255' terminated string
		cp 255
		ret z
		inc hl
		call PrintChar
		jr PrintString

Message: 
		db 'Joystick Sprites!',255
		
TheTEXT: 
		db 'This is a TEST!!',255

keyTEXT:
	ld h,3 
	ld l,10
	call TextCursor
	ld hl,TheTEXT
	call PrintString
	ret


; star routine..
.DrawStars    
	call stars
    	ret ; jp inflp

.stars
    ld de,#0000
    ld hl,here_2
    ld b,24
.loop_1
    ld a,(hl)
    ld e,a
    inc hl
    ld a,(hl)
    ld d,a
    dec hl
    ld a,(de)
    cp #fe
    jr nz,jump_1
    xor a
    ld (de),a
.jump_1
    inc de
    ld a,d
    cp #00
    jr nz,jump_2
    push hl
    ld hl,#C000
    add hl,de
    ex de,hl
    pop hl
.jump_2
    ld a,(de)
    cp #00
    jr nz,jump_3
    ld a,#fe
    ld (de),a
.jump_3    
    ld a,e
    ld (hl),a
    inc hl
    ld a,d
    ld (hl),a
    inc hl
    djnz loop_1

    ld hl,here_3
    ld b,24
.loop_2
    ld a,(hl)
    ld e,a
    inc hl
    ld a,(hl)
    ld d,a
    dec hl
    ld a,(de)
    cp #fe
    jr nz,jump_4
    xor a
    ld (de),a
.jump_4
    inc de
    inc de
    ld a,d
    cp #00
    jr nz,jump_5
    push hl
    ld hl,#C000
    add hl,de
    ex de,hl
    pop hl
.jump_5
    ld a,(de)
    cp #00
    jr nz,jump_6
    ld a,#fe
    ld (de),a
.jump_6
    ld a,e
    ld (hl),a
    inc hl
    ld a,d
    ld (hl),a
    inc hl
    djnz loop_2
    ret
.here_2
db #00,#c0,#55,#c0,#c0,#c0,#f4,#c0
;db #c0,#f4,#c0,#c0,#c0,#55,#c0,#00
db #68,#c1,#a9,#c1,#20,#c2,#55,#c2
;db #c2,#55,#c2,#20,#c1,#a9,#c1,#68
db #82,#c2,#e0,#c2,#4a,#c3,#a0,#c3
;db #c3,#a0,#c3,#4a,#c2,#e0,#c2,#82
db #d9,#c3,#49,#c4,#a0,#c4,#d9,#c4
;db #c4,#d9,#c4,#a0,#c4,#49,#c3,#d9
db #48,#c5,#65,#c5,#c6,#c5,#fa,#c5
;db #c5,#fa,#c5,#c6,#c5,#65,#c5,#45
db #85,#c6,#d5,#c6,#20,#c7,#49,#c7
;db #c7,#49,#c7,#20,#c6,#d5,#c6,#85
db #a0,#c7
;db #c7,#a0

.here_3
db #30,#d0,#90,#d8,#a0,#f0,#10,#d1
db #7a,#e1,#a0,#e9,#00,#ca,#30,#d2
db #b0,#e2,#e0,#ea,#50,#d3,#75,#db
db #e0,#f3,#20,#d4,#a0,#cc,#e9,#dc
db #0a,#ed,#65,#dd,#a9,#d5,#15,#f6
db #85,#ee,#a5,#ee,#ff,#ce,#4a,#e7
db #b0,#ef

