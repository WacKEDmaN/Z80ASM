;; Draw loop  in Assembly

ORG &4000	;; call &4000 from basic to run

;; Initialiation stuff

ld a,1
call &bc0e 	;; SCR SET MODE, Routine will work in any mode which is set.
ld a,1
call &bbde 	;; GRA SET PEN (PEN 1)

ld de,100	;; xpos position to start at
ld hl,100	;; ypos position to start at

call &bbc0 	;; GRA MOVE ABSOLUTE

;; Setup size of the Loop with points to plot
ld b,9 		;; number of points to loop for image
.loop 		;; The main loop

ld hl,(adrypos)	;; Address contents which points to image data for ypos goes into HL

ld e,(hl)	;; \
inc hl		;; - Contents of HL which is ypos data (16bit number) goes into DE
ld d,(hl)	;; /

ex de,hl	;; That information (ypos data) needs to go into HL register
push hl		;; But I need to protect that information so I can use HL.
ld hl,(adrxpos) ;; Address contents which points to image data for xpos goes into HL

ld e,(hl)	;; \
inc hl		;; - The same process now happens for xpos data (16bit number) going into DE
ld d,(hl)	;; /

pop hl		;; I can now restore that ypos data back into HL...
push bc		;; ...though I need to protect the loop counter.

call &bbf6	;; GRA LINE ABSOLUTE, Entry: HL = y-coordinate, DE = x-coordinate
		;; Exit: AF, BC, DE & HL corrupt.
pop bc		;; Restore loop counter.

ld hl,(adrxpos)	;; \
inc hl		;; - This moves address pointer for xpos to the following address & stores it.
inc hl		;; - Because 16bit data is being used, HL is incremented twice.
ld (adrxpos),hl	;; /

ld hl,(adrypos) ;; \
inc hl		;; - And the same thing applies for the address pointer for ypos data.
inc hl		;; - And again 16bit data is used.
ld (adrypos),hl	;; /

djnz loop	;; If loop counter hasn't being reached,
		;; loop counter is decreased by 1 until B = 0.
		;; The following address pointer will then be used.
		
ld hl,data_xpos ;; \
ld (adrxpos),hl	;; :
		;; - Once loop is finished, the data points for xpos & ypos needs to be restored.
ld hl,data_ypos	;; :
ld (adrypos),hl	;; /

ret		;; Returns to BASIC (if called from there).

.adrxpos

defw data_xpos

.adrypos

defw data_ypos

.data_xpos
defw 100,200,100,100,200,100,150,200,200,0	;; Standard graphic points to draw for xpos.
.data_ypos
defw 100,100,200,100,200,200,250,200,100,0	;; Standard graphic points to draw for ypos.
