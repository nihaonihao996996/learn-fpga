/**
 * pipeline2.v
 * Let us see how to morph our multi-cycle CPU into a pipelined CPU !
 * Step 2: cycle and instret counters
 *   (not a pipelined processor yet)
 */

`default_nettype none
`include "clockworks.v"
`include "emitter_uart.v"

/******************************************************************************/

module ProgramMemory (
   input             clk,
   input      [15:0] mem_addr,  // address to be read
   output reg [31:0] mem_rdata  // data read from memory
);
   reg [31:0] MEM [0:16383]; // 16384 4-bytes words  
                             // 64 Kb of program RAM 
   wire [13:0] word_addr = mem_addr[15:2];
   always @(posedge clk) begin
      mem_rdata <= MEM[word_addr];
   end
   initial begin
      $readmemh("PROGROM.hex",MEM);
   end
endmodule

/******************************************************************************/

module DataMemory (
   input             clk,
   input      [15:0] mem_addr,  // address to be read
   output reg [31:0] mem_rdata, // data read from memory
   input      [31:0] mem_wdata, // data to be written
   input      [3:0]  mem_wmask	// masks for writing the 4 bytes (1=write byte)
);
   reg [31:0] MEM [0:16383]; // 16384 4-bytes words 
                             // 64 Kb of data RAM in total
   wire [13:0] word_addr = mem_addr[15:2];
   always @(posedge clk) begin
      mem_rdata <= MEM[word_addr];
      if(mem_wmask[0]) MEM[word_addr][ 7:0 ] <= mem_wdata[ 7:0 ];
      if(mem_wmask[1]) MEM[word_addr][15:8 ] <= mem_wdata[15:8 ];
      if(mem_wmask[2]) MEM[word_addr][23:16] <= mem_wdata[23:16];
      if(mem_wmask[3]) MEM[word_addr][31:24] <= mem_wdata[31:24];	 
   end
   initial begin
      $readmemh("DATARAM.hex",MEM);
   end
endmodule

/******************************************************************************/

module Processor (
    input 	  clk,
    input 	  resetn,
    output [31:0] prog_mem_addr,  // program memory address 
    input [31:0]  prog_mem_rdata, // data read from program memory
    output [31:0] data_mem_addr,  // data memory address
    input [31:0]  data_mem_rdata, // data read from data memory
    output [31:0] data_mem_wdata, // data written to data memory
    output [3:0]  data_mem_wmask  // write mask (1 bit per byte)
);

   reg [31:0] PC=0;  // program counter
   reg [31:2] instr; // current instruction (ignore two LSBs, always 11)

   // See the table P. 105 in RISC-V manual
   
   // The 10 RISC-V instructions
   wire isALUreg  =  (instr[6:2] == 5'b01100); // rd <- rs1 OP rs2   
   wire isALUimm  =  (instr[6:2] == 5'b00100); // rd <- rs1 OP Iimm
   wire isBranch  =  (instr[6:2] == 5'b11000); // if(rs1 OP rs2) PC<-PC+Bimm
   wire isJALR    =  (instr[6:2] == 5'b11001); // rd <- PC+4; PC<-rs1+Iimm
   wire isJAL     =  (instr[6:2] == 5'b11011); // rd <- PC+4; PC<-PC+Jimm
   wire isAUIPC   =  (instr[6:2] == 5'b00101); // rd <- PC + Uimm
   wire isLUI     =  (instr[6:2] == 5'b01101); // rd <- Uimm   
   wire isLoad    =  (instr[6:2] == 5'b00000); // rd <- mem[rs1+Iimm]
   wire isStore   =  (instr[6:2] == 5'b01000); // mem[rs1+Simm] <- rs2
   wire isSYSTEM  =  (instr[6:2] == 5'b11100); // special
   
   // The 5 immediate formats
   wire [31:0] Uimm={    instr[31],   instr[30:12], {12{1'b0}}};
   wire [31:0] Iimm={{21{instr[31]}}, instr[30:20]};
   /* verilator lint_off UNUSED */ // MSBs of SBJimms are not used by addr adder
   wire [31:0] Simm={{21{instr[31]}}, instr[30:25],instr[11:7]};
   wire [31:0] Bimm={{20{instr[31]}}, instr[7],instr[30:25],instr[11:8],1'b0};
   wire [31:0] Jimm={{12{instr[31]}}, instr[19:12],instr[20],instr[30:21],1'b0};
   /* verilator lint_on UNUSED */

   // Destination registers
   wire [4:0] rdId  = instr[11:7];
   
   // function codes
   wire [2:0] funct3 = instr[14:12];
   wire [6:0] funct7 = instr[31:25];

   // SYSTEM: EBREAK and CSRRS
   wire isEBREAK     = isSYSTEM & (funct3 == 3'b000);
   wire isCSRRS      = isSYSTEM & (funct3 == 3'b010);
   
   // The registers bank
   reg [31:0] RegisterBank [0:31];
   reg [31:0] rs1; // value of source
   reg [31:0] rs2; //  registers.
   wire [31:0] writeBackData; // data to be written to rd
   wire        writeBackEn;   // asserted if data should be written to rd

   reg [63:0] cycle;   
   reg [63:0] instret;

   always @(posedge clk) begin
      cycle <= cycle + 1;
   end
   
`ifdef BENCH   
   integer     i;
   initial begin
      cycle = 0;
      instret = 0;
      for(i=0; i<32; ++i) begin
	 RegisterBank[i] = 0;
      end
   end
`endif   

   // The ALU
   wire [31:0] aluIn1 = rs1;
   wire [31:0] aluIn2 = isALUreg | isBranch ? rs2 : Iimm;

   wire [4:0] shamt = isALUreg ? rs2[4:0] : instr[24:20]; // shift amount

   // The adder is used by both arithmetic instructions and JALR.
   wire [31:0] aluPlus = aluIn1 + aluIn2;

   // Use a single 33 bits subtract to do subtraction and all comparisons
   // (trick borrowed from swapforth/J1)
   wire [32:0] aluMinus = {1'b1, ~aluIn2} + {1'b0,aluIn1} + 33'b1;
   wire        LT  = (aluIn1[31] ^ aluIn2[31]) ? aluIn1[31] : aluMinus[32];
   wire        LTU = aluMinus[32];
   wire        EQ  = (aluMinus[31:0] == 0);

   // Flip a 32 bit word. Used by the shifter (a single shifter for
   // left and right shifts, saves silicium !)
   function [31:0] flip32;
      input [31:0] x;
      flip32 = {x[ 0], x[ 1], x[ 2], x[ 3], x[ 4], x[ 5], x[ 6], x[ 7], 
		x[ 8], x[ 9], x[10], x[11], x[12], x[13], x[14], x[15], 
		x[16], x[17], x[18], x[19], x[20], x[21], x[22], x[23],
		x[24], x[25], x[26], x[27], x[28], x[29], x[30], x[31]};
   endfunction

   wire [31:0] shifter_in = (funct3 == 3'b001) ? flip32(aluIn1) : aluIn1;
   
   /* verilator lint_off WIDTH */
   wire [31:0] shifter = 
               $signed({instr[30] & aluIn1[31], shifter_in}) >>> aluIn2[4:0];
   /* verilator lint_on WIDTH */

   wire [31:0] leftshift = flip32(shifter);
   

   
   // ADD/SUB/ADDI: 
   // funct7[5] is 1 for SUB and 0 for ADD. We need also to test instr[5]
   // to make the difference with ADDI
   //
   // SRLI/SRAI/SRL/SRA: 
   // funct7[5] is 1 for arithmetic shift (SRA/SRAI) and 
   // 0 for logical shift (SRL/SRLI)
   reg [31:0]  aluOut;
   always @(*) begin
      case(funct3)
	3'b000: aluOut = (funct7[5] & instr[5]) ? aluMinus[31:0] : aluPlus;
	3'b001: aluOut = leftshift;
	3'b010: aluOut = {31'b0, LT};
	3'b011: aluOut = {31'b0, LTU};
	3'b100: aluOut = (aluIn1 ^ aluIn2);
	3'b101: aluOut = shifter;
	3'b110: aluOut = (aluIn1 | aluIn2);
	3'b111: aluOut = (aluIn1 & aluIn2);	
      endcase
   end

   // The predicate for branch instructions
   reg takeBranch;
   always @(*) begin
      case(funct3)
	3'b000: takeBranch = EQ;
	3'b001: takeBranch = !EQ;
	3'b100: takeBranch = LT;
	3'b101: takeBranch = !LT;
	3'b110: takeBranch = LTU;
	3'b111: takeBranch = !LTU;
	default: takeBranch = 1'b0;
      endcase
   end
   

   // Address computation

   // An adder used to compute branch address, JAL address and AUIPC.
   // branch->PC+Bimm    AUIPC->PC+Uimm    JAL->PC+Jimm
   // Equivalent to PCplusImm = PC + (isJAL ? Jimm : isAUIPC ? Uimm : Bimm)

   // Note: doing so with ADDR_WIDTH < 32, AUIPC may fail in 
   // some RISC-V compliance tests because one can is supposed to use 
   // it to generate arbitrary 32-bit values (and not only addresses).
   
   wire [31:0] PCplusImm = PC + ( instr[3] ? Jimm[31:0] :
					    instr[4] ? Uimm[31:0] :
				            Bimm[31:0] );
   wire [31:0] PCplus4 = PC+4;
   

   wire [31:0] nextPC = 
               ((isBranch && takeBranch) || isJAL) ? PCplusImm            :
	                                    isJALR ? {aluPlus[31:1],1'b0} :
	                                             PCplus4;

   wire [31:0] loadstore_addr = rs1 + (isStore ? Simm : Iimm);


   // register write back
   // CYCLE, CYCLEH, INSTRET, INSTRETH
   wire [31:0] CSR_data =
	       ( instr[27] & instr[21]) ? instret[63:32]:
	       (!instr[27] & instr[21]) ? instret[31:0] :
	             instr[27]          ? cycle[63:32]  :
 	                                  cycle[31:0]   ;
   
   assign writeBackData = (isJAL || isJALR) ? PCplus4   :
			      isLUI         ? Uimm      :
			      isAUIPC       ? PCplusImm :
			      isLoad        ? LOAD_data :
			      isCSRRS       ? CSR_data  :
			                      aluOut;
   // Load
   // All memory accesses are aligned on 32 bits boundary. For this
   // reason, we need some circuitry that does unaligned halfword
   // and byte load/store, based on:
   // - funct3[1:0]:  00->byte 01->halfword 10->word
   // - data_mem_addr[1:0]: indicates which byte/halfword is accessed

   wire data_mem_byteAccess     = funct3[1:0] == 2'b00;
   wire data_mem_halfwordAccess = funct3[1:0] == 2'b01;

   wire [15:0] LOAD_halfword =
	       loadstore_addr[1] ? data_mem_rdata[31:16] : data_mem_rdata[15:0];

   wire  [7:0] LOAD_byte =
	       loadstore_addr[0] ? LOAD_halfword[15:8] : LOAD_halfword[7:0];

   // LOAD, in addition to funct3[1:0], LOAD depends on:
   // - funct3[2] (instr[14]): 0->do sign expansion   1->no sign expansion
   wire LOAD_sign =
	!funct3[2] & (data_mem_byteAccess ? LOAD_byte[7] : LOAD_halfword[15]);

   wire [31:0] LOAD_data =
         data_mem_byteAccess ? {{24{LOAD_sign}},     LOAD_byte} :
     data_mem_halfwordAccess ? {{16{LOAD_sign}}, LOAD_halfword} :
                          data_mem_rdata ;

   // Store
   // ------------------------------------------------------------------------

   assign data_mem_wdata[ 7: 0] = rs2[7:0];
   assign data_mem_wdata[15: 8] = loadstore_addr[0] ? rs2[7:0]  : rs2[15: 8];
   assign data_mem_wdata[23:16] = loadstore_addr[1] ? rs2[7:0]  : rs2[23:16];
   assign data_mem_wdata[31:24] = loadstore_addr[0] ? rs2[7:0]  :
				  loadstore_addr[1] ? rs2[15:8] : rs2[31:24];

   // The memory write mask:
   //    1111                     if writing a word
   //    0011 or 1100             if writing a halfword
   //                                (depending on loadstore_addr[1])
   //    0001, 0010, 0100 or 1000 if writing a byte
   //                                (depending on loadstore_addr[1:0])

   wire [3:0] STORE_wmask =
	      data_mem_byteAccess      ?
	            (loadstore_addr[1] ?
		          (loadstore_addr[0] ? 4'b1000 : 4'b0100) :
		          (loadstore_addr[0] ? 4'b0010 : 4'b0001)
                    ) :
	      data_mem_halfwordAccess ?
	            (loadstore_addr[1] ? 4'b1100 : 4'b0011) :
              4'b1111;
   
   // The state machine
   localparam FETCH_INSTR = 0;
   localparam WAIT_INSTR  = 1;
   localparam EXECUTE     = 2;
   localparam WAIT_DATA   = 3;
   reg [1:0] state = FETCH_INSTR;
   
   always @(posedge clk) begin
      if(!resetn) begin
	 PC      <= 32'h00000000;
	 cycle   <= 0;
	 instret <= 0;
	 state <= WAIT_DATA;    // just wait for !mem_rbusy
      end else begin
	 if(writeBackEn && rdId != 0) begin
	    RegisterBank[rdId] <= writeBackData;
	 end
	 case(state)
	   FETCH_INSTR: begin
	      state <= WAIT_INSTR;
`ifdef BENCH
	      if(PC >= 32'h10000) begin
		 $display("invalid PC, out of range: %h",PC);
		 $finish();
	      end
`endif	      
	   end
	   WAIT_INSTR: begin
	      instr <= prog_mem_rdata[31:2];
	      rs1 <= RegisterBank[prog_mem_rdata[19:15]];
	      rs2 <= RegisterBank[prog_mem_rdata[24:20]];
	      state <= EXECUTE;
	      instret <= instret + 1;
	   end
	   EXECUTE: begin
	      if(!isEBREAK) begin
		 PC <= nextPC;
	      end
	      state <= isLoad  ? WAIT_DATA : FETCH_INSTR;
`ifdef BENCH
	      if(isLoad || isStore) begin
		 if(data_mem_addr <  32'h10000) begin
		    $display("invalid data addr: %h",data_mem_addr);
		    $finish();
		 end
	      end
	      if(isEBREAK) $finish();
`endif      
	   end
	   WAIT_DATA: begin
	      state <= FETCH_INSTR;
	   end
	 endcase 
      end
   end

   assign writeBackEn = (state==EXECUTE && !isBranch && !isStore) ||
			(state==WAIT_DATA) ;
   assign data_mem_addr = loadstore_addr;
   assign prog_mem_addr = PC;
   assign data_mem_wmask = {4{(state == EXECUTE) & isStore}} & STORE_wmask;
endmodule


module SOC (
    input 	     CLK, // system clock 
    input 	     RESET,// reset button
    output reg [4:0] LEDS, // system LEDs
    input 	     RXD, // UART receive
    output 	     TXD, // UART transmit
    output 	     SPIFLASH_CLK,  // SPI flash clock
    output 	     SPIFLASH_CS_N, // SPI flash chip select (active low)
    inout [1:0]      SPIFLASH_IO    // SPI flash IO pins
);

   wire clk;
   wire resetn;

   wire [31:0] prog_mem_addr;
   wire [31:0] prog_mem_rdata;
   
   wire [31:0] data_mem_addr;
   wire [31:0] data_mem_rdata;
   wire [31:0] data_mem_wdata;
   wire [3:0]  data_mem_wmask;

   Processor CPU(
      .clk(clk),
      .resetn(resetn),
      .prog_mem_addr(prog_mem_addr),
      .prog_mem_rdata(prog_mem_rdata),
      .data_mem_addr(data_mem_addr),
      .data_mem_rdata(data_mem_rdata),
      .data_mem_wdata(data_mem_wdata),
      .data_mem_wmask(data_mem_wmask)
   );

   /*
    * Memory map: three pages of 64kB each
    *   page 0: instruction mem (readonly)
    *   page 1: data mem        (readwrite)
    *   page 2: IO              (readwrite)
    *
    *  mem_addr[15:0] : offset in page
    *  mem_addr[16]   : data / code
    *  mem_addr[22]   : IO (same bit as the rest of this tutorial)
    */
   
   wire [31:0] RAM_rdata;
   wire [13:0] mem_wordaddr = data_mem_addr[15:2];
   wire        isIO         = data_mem_addr[22];
   wire        isRAM        = !isIO;
   wire        mem_wstrb    = |data_mem_wmask;

   ProgramMemory progROM(
      .clk(clk),
      .mem_addr(prog_mem_addr[15:0]),
      .mem_rdata(prog_mem_rdata)
   );
   
   DataMemory RAM(
      .clk(clk),
      .mem_addr(data_mem_addr[15:0]),
      .mem_rdata(RAM_rdata),
      .mem_wdata(data_mem_wdata),
      .mem_wmask({4{isRAM}}&data_mem_wmask)
   );
   
   // Memory-mapped IO in IO page, 1-hot addressing in word address.   
   localparam IO_LEDS_bit      = 0;  // W five leds
   localparam IO_UART_DAT_bit  = 1;  // W data to send (8 bits) 
   localparam IO_UART_CNTL_bit = 2;  // R status. bit 9: busy sending
   
   always @(posedge clk) begin
      if(isIO & mem_wstrb & mem_wordaddr[IO_LEDS_bit]) begin
	 LEDS <= data_mem_wdata[4:0];
      end
   end

   wire uart_valid = isIO & mem_wstrb & mem_wordaddr[IO_UART_DAT_bit];
   wire uart_ready;

   corescore_emitter_uart #(
      .clk_freq_hz(`CPU_FREQ*1000000),
        .baud_rate(1000000)
   ) UART(
      .i_clk(clk),
      .i_rst(!resetn),
      .i_data(data_mem_wdata[7:0]),
      .i_valid(uart_valid),
      .o_ready(uart_ready),
      .o_uart_tx(TXD)      			       
   );
   
   wire [31:0] IO_rdata = 
	       mem_wordaddr[IO_UART_CNTL_bit] ? { 22'b0, !uart_ready, 9'b0}
	                                      : 32'b0;

   assign data_mem_rdata = isRAM ? RAM_rdata : IO_rdata ;

`ifdef BENCH
   always @(posedge clk) begin
      if(uart_valid) begin
	 $write("%c", data_mem_wdata[7:0] );
	 $fflush(32'h8000_0001);
      end
   end
`endif   
   
   // Gearbox and reset circuitry.
   Clockworks CW(
     .CLK(CLK),
     .RESET(RESET),
     .clk(clk),
     .resetn(resetn)
   );

endmodule

 