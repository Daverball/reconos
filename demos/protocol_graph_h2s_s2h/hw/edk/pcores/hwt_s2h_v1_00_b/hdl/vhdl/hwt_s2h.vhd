library ieee;
use ieee.std_logic_1164.all;
--use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;

library reconos_v3_00_b;
use reconos_v3_00_b.reconos_pkg.all;

library ana_v1_00_a;
use ana_v1_00_a.anaPkg.all;


entity hwt_s2h is
	port (
		OSFSL_S_Read    : out std_logic;                 -- Read signal, requiring next available input to be read
		OSFSL_S_Data    : in  std_logic_vector(0 to 31); -- Input data
		OSFSL_S_Control : in  std_logic;                 -- Control Bit, indicating the input data are control word
		OSFSL_S_Exists  : in  std_logic;                 -- Data Exist Bit, indicating data exist in the input FSL bus
		OSFSL_M_Write   : out std_logic;                 -- Write signal, enabling writing to output FSL bus
		OSFSL_M_Data    : out std_logic_vector(0 to 31); -- Output data
		OSFSL_M_Control : out std_logic;                 -- Control Bit, indicating the output data are contol word
		OSFSL_M_Full    : in  std_logic;                 -- Full Bit, indicating output FSL bus is full		
		-- FIFO Interface
		FIFO32_S_Data : in std_logic_vector(31 downto 0);
		FIFO32_M_Data : out std_logic_vector(31 downto 0);
		FIFO32_S_Fill : in std_logic_vector(15 downto 0);
		FIFO32_M_Rem : in std_logic_vector(15 downto 0);
		FIFO32_S_Rd : out std_logic;
		FIFO32_M_Wr : out std_logic;		
		-- HWT reset
		rst           : in std_logic;
		clk		: in std_logic;
		switch_data_rdy		: in  std_logic;
		switch_data		: in  std_logic_vector(dataWidth downto 0);
		thread_read_rdy	 	: out std_logic;
		switch_read_rdy		: in  std_logic;
		thread_data		: out std_logic_vector(dataWidth downto 0);
		thread_data_rdy 	: out std_logic
	);

end hwt_s2h;

architecture implementation of hwt_s2h is

	component s2h_icon
	port (
		control0 : inout std_logic_vector(35 downto 0)
	);
	end component;

	component s2h_ila
	port (
		control : inout std_logic_vector(35 downto 0);
		clk : in std_logic;
		trig0 : in std_logic_vector(3 downto 0);
		trig1 : in std_logic_vector(7 downto 0);
		trig2 : in std_logic_vector(3 downto 0);
		trig3 : in std_logic_vector(7 downto 0);
		trig4 : in std_logic_vector(31 downto 0);
		trig5 : in std_logic_vector(15 downto 0);
		trig6 : in std_logic_vector(31 downto 0)
	);
	end component;

	type STATE_TYPE is ( STATE_INIT, STATE_GET_LEN, STATE_READ, STATE_WAIT, STATE_WRITE, STATE_PULL, STATE_PUT, STATE_PUT2,STATE_PUT3, STATE_PUT4, STATE_THREAD_EXIT
	);

	constant MBOX_RECV  : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000000";
	constant MBOX_SEND  : std_logic_vector(C_FSL_WIDTH-1 downto 0) := x"00000001";

	signal data     : std_logic_vector(31 downto 0);
	signal state    : STATE_TYPE;
	signal i_osif   : i_osif_t;
	signal o_osif   : o_osif_t;
	signal i_memif  : i_memif_t;
	signal o_memif  : o_memif_t;
	signal i_ram    : i_ram_t;
	signal o_ram    : o_ram_t;

	signal ignore   : std_logic_vector(C_FSL_WIDTH-1 downto 0);

	-- IMPORTANT: define size of local RAM here!!!! 
	constant C_LOCAL_RAM_SIZE          : integer := 16384; --64kB
	constant C_LOCAL_RAM_ADDRESS_WIDTH : integer := clog2(C_LOCAL_RAM_SIZE);
	constant C_LOCAL_RAM_SIZE_IN_BYTES : integer := 4*C_LOCAL_RAM_SIZE;
	
	-- IMPORTANT: define maximum and minimum packet lengths here
	constant C_MAX_PACKET_LEN : integer := 1500;
	constant C_MIN_PACKET_LEN : integer := 64;

	type LOCAL_MEMORY_T is array (0 to C_LOCAL_RAM_SIZE-1) of std_logic_vector(31 downto 0);
	signal o_RAMAddr_sender : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	signal o_RAMData_sender : std_logic_vector(0 to 31);
	signal o_RAMWE_sender   : std_logic;
	signal i_RAMData_sender : std_logic_vector(0 to 31);

	signal o_RAMAddr_reconos   : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	signal o_RAMAddr_reconos_2 : std_logic_vector(0 to 31);
	signal o_RAMData_reconos   : std_logic_vector(0 to 31);
	signal o_RAMWE_reconos     : std_logic;
	signal i_RAMData_reconos   : std_logic_vector(0 to 31);
	
	constant o_RAMAddr_max : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1) := (others=>'1');

	shared variable local_ram : LOCAL_MEMORY_T;

	type testing_state_t is (T_STATE_INIT, T_STATE_RCV);
	signal testing_state 	    : testing_state_t;
	signal testing_state_next   : testing_state_t;
	
	type COUNTER_STATE_T is (STATE_INIT1, STATE_INIT2, STATE_GET_NUM, STATE_WAIT, STATE_INCREMENT, STATE_DONE);
	signal counter_state : COUNTER_STATE_T;
	
	signal packet_count        : integer range 0 to (C_LOCAL_RAM_SIZE_IN_BYTES/C_MIN_PACKET_LEN + 1);
	signal local_base_addr     : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	signal buffer_limit        : std_logic_vector(31 downto 0);
	signal packet_manager_en   : std_logic;
	signal packet_manager_done : std_logic;

	type SENDING_STATE_TYPE_T is (STATE_IDLE, STATE_READ_LEN_WAIT_A, STATE_WAIT_IDP_A, STATE_READ_LEN,STATE_SRCIDP, STATE_DSTIDP, STATE_WAIT_SOF,
						STATE_SEND_SOF, STATE_SEND_SECOND, STATE_SEND_THIRD, STATE_SEND_FOURTH, 
						STATE_SEND_DATA_1, STATE_SEND_DATA_2, STATE_SEND_DATA_3, STATE_SEND_DATA_4,
						 STATE_SEND_EOF_1, STATE_SEND_EOF_2, STATE_SEND_EOF_3, STATE_SEND_EOF_4, STATE_WAIT
	);

	signal sending_state : SENDING_STATE_TYPE_T;
	
	signal rx_packet_count 	    : std_logic_vector(31 downto 0);
	signal rx_packet_count_next : std_logic_vector(31 downto 0);

	signal tx_testing_state 	    : testing_state_t;
	signal tx_testing_state_next   : testing_state_t;

	signal tx_packet_count 	    : std_logic_vector(31 downto 0);
	signal tx_packet_count_next : std_logic_vector(31 downto 0);
	
	signal rx_ll_dst_rdy_local	: std_logic;

	signal tx_ll_sof	: std_logic;
	signal tx_ll_eof	: std_logic;
	signal tx_ll_data	: std_logic_vector(7 downto 0);
	signal tx_ll_src_rdy	: std_logic;
	signal tx_ll_dst_rdy	: std_logic;

	signal rx_ll_sof	: std_logic;
	signal rx_ll_eof	: std_logic;
	signal rx_ll_data	: std_logic_vector(7 downto 0);
	signal rx_ll_src_rdy	: std_logic;
	signal rx_ll_dst_rdy	: std_logic;

	signal payload_count : integer range 0 to 1500;
	signal payload_count_next : integer range 0 to 1500;

	signal global_addr : std_logic_vector(0 to 3);
	signal local_addr : std_logic_vector(0 to 1);
	signal data_ready : std_logic;
	signal packets_sent : std_logic;
	
	signal total_packet_len : std_logic_vector(15 downto 0);
	signal debug_packet_len : std_logic_vector(31 downto 0);
	signal debug_packet_len2 : std_logic_vector(31 downto 0);
	
	signal tx_data_word : std_logic_vector(0 to 31);
	
	signal send_packet_done : std_logic;
	signal send_packet_en : std_logic;
	
	signal base_addr : std_logic_vector(31 downto 0);
	signal len		: std_logic_vector(31 downto 0);
	signal data_from_ram : std_logic_vector(31 downto 0);
	signal direction : std_logic;
	signal priority : std_logic_vector(0 to 1);
	signal latencyCritical : std_logic;
	signal srcIdp : std_logic_vector(0 to 31);
	signal dstIdp : std_logic_vector(0 to 31);
	
	signal reconos_fsm : std_logic_vector(2 downto 0);
	signal fsm_step : std_logic_vector(4 downto 0);
	
--	signal control : std_logic_vector(35 downto 0);
--	signal trig0   : std_logic_vector(3 downto 0);
--	signal trig1   : std_logic_vector(7 downto 0);
--	signal trig2   : std_logic_vector(3 downto 0);
--	signal trig3   : std_logic_vector(7 downto 0);
--	signal trig4   : std_logic_vector(31 downto 0);
--	signal trig5   : std_logic_vector(15 downto 0);
--	signal trig6   : std_logic_vector(31 downto 0);
	
begin

--	--GENERATE_ILA : if C_ENABLE_ILA = 1 generate
--	icon_i : s2h_icon
--	port map (
--		control0 => control
--	);
--	
--	ila_i : s2h_ila
--	port map (
--		control => control,
--		clk   => clk,
--		trig0 => trig0,
--		trig1 => trig1,
--		trig2 => trig2,
--		trig3 => trig3,
--		trig4 => trig4,
--		trig5 => trig5,
--		trig6 => trig6
--	);
--	--end generate;
--
--	trig0 <= rst & "0" & send_packet_en & send_packet_done;
--	trig1 <= reconos_fsm & fsm_step;
--	trig2 <= tx_ll_sof & tx_ll_eof & tx_ll_src_rdy & tx_ll_dst_rdy;
--	trig3 <= tx_ll_data;
--	trig4 <= tx_data_word;
--	trig5 <= o_RAMAddr_sender & "0000" & o_RAMWE_sender;
--	trig6 <= i_RAMData_sender;
	

	decoder_inst : packetDecoder
	port map (
		clk 	=> clk,
		reset 	=> rst,
		-- Signals from the switch
		switch_data_rdy		=> switch_data_rdy,
		switch_data		=> switch_data,
		thread_read_rdy		=> thread_read_rdy,
		-- Decoded values of the packet
		noc_rx_sof		=> rx_ll_sof,		-- Indicates the start of a new packet
		noc_rx_eof		=> rx_ll_eof,		-- Indicates the end of the packet
		noc_rx_data		=> rx_ll_data,		-- The current data byte
		noc_rx_src_rdy		=> rx_ll_src_rdy, 	-- '1' if the data are valid, '0' else
		noc_rx_direction	=> open,		-- '1' for egress, '0' for ingress
		noc_rx_priority		=> open,		-- The priority of the packet
		noc_rx_latencyCritical	=> open,		-- '1' if this packet is latency critical
		noc_rx_srcIdp		=> open,		-- The source IDP
		noc_rx_dstIdp		=> open,		-- The destination IDP
		noc_rx_dst_rdy		=> rx_ll_dst_rdy	-- Read enable for the functional block
	);
	
	encoder_inst : packetEncoder
	port map(
		clk 				=> clk,					
		reset 				=> rst,		
		-- Signals to the switch
		switch_read_rdy  		=> switch_read_rdy, 		
		thread_data  			=> thread_data,		
		thread_data_rdy 		=> thread_data_rdy,
		-- Decoded values of the packet
		noc_tx_sof  			=> tx_ll_sof, 		
		noc_tx_eof  			=> tx_ll_eof,
		noc_tx_data	 			=> tx_ll_data,		
		noc_tx_src_rdy 	 		=> tx_ll_src_rdy,		
		noc_tx_globalAddress  	=> global_addr, 	
		noc_tx_localAddress 	=> local_addr,		
		noc_tx_direction 	 	=> direction, 		
		noc_tx_priority 	 	=> priority,		
		noc_tx_latencyCritical 	=> latencyCritical,	
		noc_tx_srcIdp 			=> srcIdp,	
		noc_tx_dstIdp 			=> dstIdp,
		noc_tx_dst_rdy	 		=> tx_ll_dst_rdy
	);	

	-- local dual-port RAM
	local_ram_ctrl_1 : process (clk) is
	begin
		if (rising_edge(clk)) then
			if (o_RAMWE_reconos = '1') then
				local_ram(to_integer(unsigned(o_RAMAddr_reconos))) := o_RAMData_reconos;
			else
				i_RAMData_reconos <= local_ram(to_integer(unsigned(o_RAMAddr_reconos)));
			end if;
		end if;
	end process;
			
	local_ram_ctrl_2 : process (clk) is
	begin
		if (rising_edge(clk)) then		
			if (o_RAMWE_sender = '1') then
				local_ram(to_integer(unsigned(o_RAMAddr_sender))) := o_RAMData_sender;
			else
				i_RAMData_sender <= local_ram(to_integer(unsigned(o_RAMAddr_sender)));
			end if;
		end if;
	end process;
	
	-- the userlogic does not write anything to the local ram (only the ReconOS FSM)
	o_RAMWE_sender <= '0';
	o_RAMData_sender <= (others => '0');

	-- setup fsl, memif, ram
	fsl_setup(i_osif,o_osif,OSFSL_S_Data,OSFSL_S_Exists,OSFSL_M_Full,OSFSL_M_Data,OSFSL_S_Read,OSFSL_M_Write,OSFSL_M_Control);
	memif_setup(i_memif,o_memif,FIFO32_S_Data,FIFO32_S_Fill,FIFO32_S_Rd,FIFO32_M_Data,FIFO32_M_Rem,FIFO32_M_Wr);
	ram_setup(i_ram,o_ram,o_RAMAddr_reconos_2,o_RAMData_reconos,i_RAMData_reconos,o_RAMWE_reconos);
	
	o_RAMAddr_reconos(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1) <= o_RAMAddr_reconos_2((32-C_LOCAL_RAM_ADDRESS_WIDTH) to 31);
	
	--we are always ready to receive packets (which will be ignored)
	rx_ll_dst_rdy <= rx_ll_dst_rdy_local;
	rx_ll_dst_rdy_local <= '1';

	-- send packet from RAM
	send_packet : process (clk, rst, send_packet_en)
	begin
		if rst = '1' or send_packet_en='0' then
			o_RAMAddr_sender <= (others => '0');
			sending_state <= STATE_IDLE;
			tx_ll_src_rdy <= '0';
			tx_ll_data <= (others => '0');
			tx_ll_sof <= '0';
			tx_ll_eof <= '0';
			tx_data_word <= (others => '0');
			total_packet_len <= (others => '0');
			payload_count <= 0;
			packets_sent <= '0';				
			debug_packet_len2 <= (others => '0');		
			global_addr  <= (others  => '0');
			local_addr  <= (others  => '0');
			priority  <= (others  => '0');
			direction  <= '0';
			latencycritical  <= '0';
			send_packet_done<='0';
			srcIdp  <= (others  => '0');
			dstIdp  <= (others  => '0');		
			fsm_step <= "00000";
		elsif rising_edge(clk) then
			--default assignement
			tx_ll_data <= (others => '0');
			tx_ll_sof <= '0';
			tx_ll_eof <= '0';
			tx_ll_src_rdy <= '1';
			packets_sent <= '0';
		case sending_state is
			when STATE_IDLE =>
				fsm_step <= "00001";
				send_packet_done<='0';
				tx_ll_src_rdy <= '0';
				payload_count <= 0;
				o_RAMAddr_sender <= local_base_addr; 			-- Addr 0
				--if data_ready = '1' then
					sending_state <= STATE_READ_LEN_WAIT_A;
				--end if;
			when STATE_READ_LEN_WAIT_A =>
				fsm_step <= "00010";
				tx_ll_src_rdy <= '0';
				o_RAMAddr_sender <= o_RAMAddr_sender + 1;		-- Addr 1
				sending_state <= STATE_READ_LEN;
			when STATE_READ_LEN =>
				fsm_step <= "00011";
				o_RAMAddr_sender <= o_RAMAddr_sender + 1;		-- Addr 0 valid, Addr 2
				tx_ll_src_rdy <= '0';
				debug_packet_len2 <= i_RAMData_sender;
				global_addr  <= i_RAMData_sender(0 to 3);
				local_addr  <= i_RAMData_sender(4 to 5);
				priority  <= i_RAMData_sender(6 to 7);
				direction  <= i_RAMData_sender(8);
				latencyCritical  <= i_RAMData_sender(9);
				total_packet_len  <= i_RAMData_sender(16 to 31);
				sending_state <= STATE_SRCIDP;
			when STATE_SRCIDP =>
				fsm_step <= "00100";
				o_RAMAddr_sender <= o_RAMAddr_sender + 1;		 -- Addr 1 valid, Addr 3
				tx_ll_src_rdy <= '0';
				srcIDP  <= i_RAMData_sender;
				sending_state <= STATE_DSTIDP;
			when STATE_DSTIDP =>
				fsm_step <= "00101";
				tx_ll_src_rdy <= '0';
				sending_state <= STATE_SEND_SOF;
				dstIDP  <= i_RAMData_sender;		
			when STATE_SEND_SOF =>
				fsm_step <= "00110";
				tx_data_word <= i_RAMData_sender;				-- Addr 3 valid
				tx_ll_data <= i_RAMData_sender(0 to 7); 
				tx_ll_sof <= '1';
				if tx_ll_dst_rdy = '1' then
					sending_state <= STATE_SEND_SECOND;
					tx_ll_data <= tx_data_word(8 to 15);
				end if;
			when STATE_SEND_SECOND => 
				fsm_step <= "00111";
				if tx_ll_dst_rdy = '1' then
					o_RAMAddr_sender <= o_RAMAddr_sender + 1;
					tx_ll_data <= tx_data_word(16 to 23);
					sending_state <= STATE_SEND_THIRD;
				end if;
			when STATE_SEND_THIRD =>
				fsm_step <= "01000";
				if tx_ll_dst_rdy = '1' then
					tx_ll_data <= tx_data_word(24 to 31);
					sending_state <= STATE_SEND_FOURTH;
				end if;
			when STATE_SEND_FOURTH =>
				fsm_step <= "01001";
				if tx_ll_dst_rdy = '1' then
					sending_state <= STATE_SEND_DATA_1;
					payload_count <= 4;
					tx_data_word <= i_RAMData_sender;
					tx_ll_data <= i_RAMData_sender(0 to 7);
				end if;
			when STATE_SEND_DATA_1 =>
				fsm_step <= "01010";
				if tx_ll_dst_rdy = '1' then
					sending_state <= STATE_SEND_DATA_2;
					tx_ll_data <= tx_data_word(8 to 15);
				end if;
			when STATE_SEND_DATA_2 =>
				fsm_step <= "01011";
				if tx_ll_dst_rdy = '1' then			
					o_RAMAddr_sender <= o_RAMAddr_sender + 1;
					sending_state <= STATE_SEND_DATA_3;				
					tx_ll_data <= tx_data_word(16 to 23);	
				end if;
			when STATE_SEND_DATA_3 =>
				fsm_step <= "01100";
				if tx_ll_dst_rdy = '1' then
					sending_state <= STATE_SEND_DATA_4;
					tx_ll_data <= tx_data_word(24 to 31);
				end if;
			when STATE_SEND_DATA_4 =>
				fsm_step <= "01101";
				if tx_ll_dst_rdy = '1' then
					if (payload_count + 8) >= unsigned(total_packet_len) then
						payload_count <= payload_count + 4;
						sending_state <= STATE_SEND_EOF_1;
						tx_data_word <= i_RAMData_sender;
						tx_ll_data <= i_RAMData_sender(0 to 7);
					else
						payload_count <= payload_count + 4;
						sending_state <= STATE_SEND_DATA_1;
						tx_data_word <= i_RAMData_sender;
						tx_ll_data <= i_RAMData_sender(0 to 7);
					end if;	
					if (payload_count + 5) = unsigned(total_packet_len) then
						sending_state <= STATE_SEND_EOF_4;
						tx_ll_eof <= '1';
					end if;	
				end if;
			when STATE_SEND_EOF_1 =>
				fsm_step <= "01110";
				if tx_ll_dst_rdy = '1' then
					sending_state <= STATE_SEND_EOF_2;
					tx_ll_data <= tx_data_word(8 to 15);
					if (payload_count + 2) = unsigned(total_packet_len) then
						sending_state <= STATE_SEND_EOF_4;
						tx_ll_eof <= '1';
					end if;
				end if;
			when STATE_SEND_EOF_2 => 
				fsm_step <= "01111";
				if tx_ll_dst_rdy = '1' then
					sending_state <= STATE_SEND_EOF_3;
					tx_ll_data <= tx_data_word(16 to 23);
					if (payload_count + 3) = unsigned(total_packet_len) then
						sending_state <= STATE_SEND_EOF_4;
						tx_ll_eof <= '1';
					end if;
				end if;
			when STATE_SEND_EOF_3 =>
				fsm_step <= "10000";
				if tx_ll_dst_rdy = '1' then
					sending_state <= STATE_SEND_EOF_4;
					tx_ll_data <= tx_data_word(24 to 31);
					tx_ll_eof <= '1';
				end if;
			when STATE_SEND_EOF_4 =>
				fsm_step <= "10001";
				--if tx_ll_dst_rdy = '1' then
					--if unsigned(o_RAMAddr_sender + 1) >= unsigned(len(16 downto 2)) then 
					sending_state <= STATE_WAIT;
					send_packet_done <= '1';
					packets_sent <= '1';
					--else
					--	sending_state  <= STATE_READ_LEN_WAIT_A;
					--	tx_ll_src_rdy <= '0';
					--	payload_count <= 0;
					--	o_RAMAddr_sender <= o_RAMAddr_sender + 1;
					--end if;
				--end if;
			when STATE_WAIT =>
				fsm_step <= "10010";
				--packets_sent <= '1';
				send_packet_done <= '1';
				--sending_state <= STATE_IDLE;
			when others => 
				fsm_step <= "11111";
				sending_state <= STATE_IDLE;
				tx_ll_src_rdy <= '0';
		end case;	
		end if;
	end process;

	--count all tx sof packets
	test_counting : process(tx_ll_sof, tx_ll_src_rdy, tx_ll_dst_rdy, rx_packet_count, testing_state) is
	variable tmp : unsigned(31 downto 0);
	begin
	    rx_packet_count_next <= rx_packet_count;
    	    testing_state_next <= testing_state;
	    case testing_state is
        	when T_STATE_INIT =>
		    rx_packet_count_next <= (others => '0');
		    testing_state_next <= T_STATE_RCV;
		when T_STATE_RCV =>
		    if tx_ll_src_rdy = '1' and tx_ll_sof = '1' and tx_ll_dst_rdy = '1' then
			tmp := unsigned(rx_packet_count) + 1;
			rx_packet_count_next <= std_logic_vector(tmp);
		    end if;
		when others =>
		    testing_state_next <= T_STATE_INIT;
	    end case;
	end process;

	-- count all tx eof packets
	tx_test_counting : process(tx_ll_eof, tx_ll_src_rdy, tx_ll_dst_rdy, tx_packet_count, tx_testing_state) is
	variable tmp : unsigned(31 downto 0);
	begin
	    tx_packet_count_next <= tx_packet_count;
    	    tx_testing_state_next <= tx_testing_state;
	    case tx_testing_state is
        	when T_STATE_INIT =>
		    tx_packet_count_next <= (others => '0');
		    tx_testing_state_next <= T_STATE_RCV;
		when T_STATE_RCV =>
		    if tx_ll_src_rdy = '1' and tx_ll_eof = '1' and tx_ll_dst_rdy = '1' then
			tmp := unsigned(tx_packet_count) + 1;
			tx_packet_count_next <= std_logic_vector(tmp);
		    end if;
		when others =>
		    tx_testing_state_next <= T_STATE_INIT;
	    end case;
	end process;

	-- creates registers
	memzing: process(clk, rst) is
	begin
	    if rst = '1' then
	        rx_packet_count <= (others => '0');
	        testing_state <= T_STATE_INIT;
	        tx_packet_count <= (others => '0');
	        tx_testing_state <= T_STATE_INIT;
	    elsif rising_edge(clk) then
	        rx_packet_count <= rx_packet_count_next;
	        testing_state <= testing_state_next;
	        tx_packet_count <= tx_packet_count_next;
	        tx_testing_state <= tx_testing_state_next;
	    end if;
	end process;
	
	-- packet_manager_fsm keeps track of where in local RAM the next packet is
	-- and makes sure we stop once there are no more packets remaining
	packet_manager: process (clk, rst, packet_manager_en) is
	variable base_addr_tmp : unsigned(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	begin
		if rst = '1' or packet_manager_en = '0' then
			local_base_addr <= (others => '0');
			packet_count <= 0;
			counter_state <= STATE_INIT1;
			send_packet_en <= '0';
			packet_manager_done <= '0';
		elsif rising_edge(clk) then
			send_packet_en <= '0';
			packet_manager_done <= '0';
			case counter_state is
				-- we don't need to set RAM address since it will always be reset to 0
				when STATE_INIT1 =>
					counter_state <= STATE_INIT2;
				-- wait for local RAM some more
				when STATE_INIT2 =>
					local_base_addr <= local_base_addr + 1; -- set to address 1 for first packet
					counter_state <= STATE_GET_NUM;
				-- read packet count
				when STATE_GET_NUM =>
					packet_count <= to_integer(unsigned(i_RAMData_sender));
					counter_state <= STATE_WAIT;
				-- wait for send_packet to do its job
				when STATE_WAIT =>
					send_packet_en <= '1';
					if send_packet_done = '1' then
						counter_state <= STATE_INCREMENT;
					end if;
				-- increment packet count and base address
				when STATE_INCREMENT =>
					if packet_count > 1 then
						packet_count <= packet_count - 1; --only increment if we got a packet of size > 0
						base_addr_tmp := unsigned(local_base_addr) + ((to_integer(unsigned(total_packet_len))+15)/4); --packet size -> payload_len+12 then round up from division by four -> +3
						local_base_addr <= std_logic_vector(base_addr_tmp);
						counter_state <= STATE_WAIT;
					else
						counter_state <= STATE_DONE;
					end if;
				when STATE_DONE =>
					packet_manager_done <= '1';
				when others =>
					counter_state <= STATE_INIT1;
			end case;
		end if;
	end process;
	
	-- os and memory synchronisation state machine
	reconos_fsm_proc: process (clk,rst,o_osif,o_memif,o_ram) is
		variable done  : boolean;
	begin
		if rst = '1' then
			osif_reset(o_osif);
			memif_reset(o_memif);
			ram_reset(o_ram);
			state <= STATE_INIT;
			done := False;
			base_addr <= (others => '0');
			len <= (others => '0');
			data_ready <= '0';
			packet_manager_en <= '0';
			reconos_fsm <= "000";
		elsif rising_edge(clk) then
			data_ready <= '0';
			packet_manager_en <= '1';
			case state is
            -- get main memory address of packet buffer
				when STATE_INIT =>
					reconos_fsm <= "001";
					osif_mbox_get(i_osif, o_osif, MBOX_RECV, base_addr, done);
					packet_manager_en <= '0';
					if done then
						state <= STATE_GET_LEN;
						base_addr <= base_addr(31 downto 2) & "00";
					end if;				
				-- get number of bytes to be copied from main memory
				when STATE_GET_LEN =>
					reconos_fsm <= "010";
					packet_manager_en <= '0';
					osif_mbox_get(i_osif, o_osif, MBOX_RECV, len, done);
					if done then
						state <= STATE_READ;
					end if;
				-- copy data from main memory to local memory
				when STATE_READ =>
					reconos_fsm <= "011";
					memif_read(i_ram,o_ram,i_memif,o_memif, base_addr, X"00000000", len(23 downto 0) + 4, done); --this is off by one word for some reason
					packet_manager_en <= '0';
					if done then
						state <= STATE_WAIT;
						packet_manager_en <= '1';
					end if;
				-- wait for packet to be send
				when STATE_WAIT =>
					reconos_fsm <= "100";
					--if packets_sent = '1' then
					if packet_manager_done = '1' then
						state <= STATE_PUT; 
						data_ready <= '0';
						len  <= (others  => '0');
					end if;					
				-- Echo the data
				when STATE_PUT =>
					reconos_fsm <= "101";
					osif_mbox_put(i_osif, o_osif, MBOX_SEND, X"0000" & total_packet_len, ignore, done);
					if done then state <= STATE_INIT; end if;				
				-- thread exit
				when STATE_THREAD_EXIT =>
					reconos_fsm <= "111";
					packet_manager_en <= '0';
					osif_thread_exit(i_osif,o_osif);					
				when others =>
					reconos_fsm <= "110";
					state <= STATE_INIT;
			end case;
		end if;
	end process;

end architecture;
