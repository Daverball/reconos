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


entity hwt_h2s is
	port (
		-- OSIF FSL
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
		-- NoC interface
		switch_data_rdy		: in  std_logic;
		switch_data		: in  std_logic_vector(dataWidth downto 0);
		thread_read_rdy	 	: out std_logic;
		switch_read_rdy		: in  std_logic;
		thread_data		: out std_logic_vector(dataWidth downto 0);
		thread_data_rdy 	: out std_logic
	);

end hwt_h2s;

architecture implementation of hwt_h2s is
	
	type STATE_TYPE is ( STATE_INIT, STATE_GET_LEN, STATE_GET_TIMEOUT, STATE_WAIT,  
			     STATE_WRITE, STATE_PUT, STATE_THREAD_EXIT
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

	-- IMPORTANT: define size of local RAM here
	constant C_LOCAL_RAM_SIZE          : integer := 16384; --64kB
	constant C_LOCAL_RAM_ADDRESS_WIDTH : integer := clog2(C_LOCAL_RAM_SIZE);
	constant C_LOCAL_RAM_SIZE_IN_BYTES : integer := 4*C_LOCAL_RAM_SIZE;
	
	-- IMPORTANT: define maximum and minimum packet lengths here
	constant C_MAX_PACKET_LEN : integer := 1500;
	constant C_MIN_PACKET_LEN : integer := 64;
	
	-- IMPORTANT: define timeout and cycles per milisecond here
	constant C_CYCLES_PER_MSECOND : integer := 100*1000;
	constant C_TIMEOUT_MAX        : integer := 10000*C_CYCLES_PER_MSECOND; --10 sec

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
	
	signal timeout_counter_en : std_logic;
	signal timeout            : std_logic;
	signal timeout_ms         : std_logic_vector(31 downto 0);
	signal timeout_cycles     : integer range 0 to C_TIMEOUT_MAX;
	signal timer              : integer range 0 to C_TIMEOUT_MAX;
	
	type COUNTER_STATE_T is (STATE_WAIT, STATE_INCREMENT, STATE_DONE);
	signal counter_state : COUNTER_STATE_T;
	
	signal packet_count        : integer range 0 to (C_LOCAL_RAM_SIZE_IN_BYTES/C_MIN_PACKET_LEN + 1);
	signal local_base_addr     : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	signal buffer_limit        : std_logic_vector(31 downto 0);
	signal packet_manager_en   : std_logic;
	signal packet_manager_done : std_logic;

	type RECEIVING_STATE_TYPE_T is (STATE_IDLE, STATE_DST_IDP, STATE_DST_WRITE, STATE_RCV_1, STATE_RCV_2, 
		STATE_RCV_3, STATE_RCV_4, STATE_EOF, STATE_WRITE_LEN, STATE_WRITE_LEN1, STATE_DONE
	);

	signal receiving_state : RECEIVING_STATE_TYPE_T;
	
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

	signal payload_count : integer range 0 to C_MAX_PACKET_LEN;
	signal payload_count_next : integer range 0 to C_MAX_PACKET_LEN;
	signal payload : std_logic_vector(31 downto 0);

	signal destination	: std_logic_vector(5 downto 0);
	signal data_ready : std_logic;
	signal packets_sent : std_logic;
	
	signal total_packet_len : std_logic_vector(21 downto 0);
	signal debug_packet_len : std_logic_vector(31 downto 0);
	signal debug_packet_len2 : std_logic_vector(31 downto 0);
	
	signal tx_data_word : std_logic_vector(0 to 31);
	
	signal base_addr : std_logic_vector(31 downto 0);
	signal base_addr_answer : std_logic_vector(31 downto 0);
	signal len		: std_logic_vector(31 downto 0);
	signal data_from_ram : std_logic_vector(31 downto 0);
	
	signal packet_received : std_logic;
	signal reconos_fsm_ready : std_logic;
	
	signal meta_data : std_logic_vector(31 downto 16);
	signal receive_packet_en : std_logic;
	signal receive_packet_done : std_logic;

	signal direction : std_logic;
	signal priority : std_logic_vector(1 downto 0);
	signal latency_critical : std_logic;
	signal srcIDP : std_logic_vector(31 downto 0);
	signal dstIDP : std_logic_vector(31 downto 0);
	
	signal reconos_step : std_logic_vector( 2 downto 0);
	signal write_step : std_logic_vector( 3 downto 0);

begin
	

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
		noc_rx_direction	=> direction, 		-- '1' for egress, '0' for ingress
		noc_rx_priority		=> priority,		-- The priority of the packet
		noc_rx_latencyCritical	=> latency_critical,		-- '1' if this packet is latency critical
		noc_rx_srcIdp		=> srcIDP,		-- The source IDP
		noc_rx_dstIdp		=> dstIDP,		-- The destination IDP
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
		noc_tx_data	 		=> tx_ll_data,		
		noc_tx_src_rdy 	 		=> tx_ll_src_rdy,		
		noc_tx_globalAddress  		=> destination(5 downto 2), 	
		noc_tx_localAddress  		=> destination(1 downto 0), 		
		noc_tx_direction 	 	=> '0',		
		noc_tx_priority 	 	=> (others  => '0'),		
		noc_tx_latencyCritical  	=> '0',	
		noc_tx_srcIdp 			=> (others  => '0'),	
		noc_tx_dstIdp 			=> (others  => '0'),
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

	fsl_setup(i_osif,o_osif,OSFSL_S_Data,OSFSL_S_Exists,OSFSL_M_Full,OSFSL_M_Data,OSFSL_S_Read,OSFSL_M_Write,OSFSL_M_Control);
	memif_setup(i_memif,o_memif,FIFO32_S_Data,FIFO32_S_Fill,FIFO32_S_Rd,FIFO32_M_Data,FIFO32_M_Rem,FIFO32_M_Wr);
	ram_setup(i_ram,o_ram,o_RAMAddr_reconos_2,o_RAMData_reconos,i_RAMData_reconos,o_RAMWE_reconos);
	
	o_RAMAddr_reconos(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1) <= o_RAMAddr_reconos_2((32-C_LOCAL_RAM_ADDRESS_WIDTH) to 31);
		
	--we are always ready and don't send any packets
	rx_ll_dst_rdy <= rx_ll_dst_rdy_local;
	tx_ll_src_rdy <= '0';
	tx_ll_sof <= '0';
	tx_ll_eof <= '0';
	tx_ll_data <= (others  => '0');
	
	--for now we send everything to destination 0
	destination(5 downto 2) <= "0001";
	destination(1 downto 0) <= "00";
	
	receive_packet : process(clk, rst, receive_packet_en)
	begin
		if rst = '1' or receive_packet_en = '0' then
			o_RAMAddr_sender <= (others => '0');
			o_RAMData_sender  <= (others  => '0');
			o_RAMWE_sender <= '0';
			rx_ll_dst_rdy_local  <= '0';
			packet_received  <= '0';
			if (rst='1') then
				payload_count  <= 0;
			end if;
			meta_data  <= (others  => '0');
			receive_packet_done <= '0';
			write_step <= "0000";
			receiving_state  <= STATE_IDLE;
		elsif rising_edge(clk) then
			rx_ll_dst_rdy_local  <= '1';
			o_RAMWE_sender <= '0';
			o_RAMData_sender <= payload;
			packet_received  <= '0';
			receive_packet_done <= '0';
			case receiving_state is
				when STATE_IDLE  => 
					write_step <= "0001";
					rx_ll_dst_rdy_local  <= '0'; 
					o_RAMAddr_sender <= (others => '0');
					if rx_ll_src_rdy = '1' and rx_ll_sof = '1' then
						--safe meta data for later, since we need to know the payload len
						meta_data(31 downto 26)  <= (others  => '0'); 
						meta_data(25 downto 24)  <= priority;
						meta_data(23)				 <= direction;
						meta_data(22)				 <= latency_critical;
						o_RAMData_sender  <= srcIDP;
						o_RAMAddr_sender  <= local_base_addr + 1;
						o_RAMWE_sender  <= '1';
						payload_count  <= 1;
						payload(31 downto 24)  <= rx_ll_data;
						receiving_state  <= STATE_DST_IDP;
						rx_ll_dst_rdy_local  <= '1';
					elsif timeout = '1' then --if we haven't gotten a packet yet and reached a timeout, skip to STATE_DONE
						payload_count <= 0;
						receiving_state <= STATE_DONE;
					end if;
				when STATE_DST_IDP  =>
	   			write_step <= "0010";
					o_RAMData_sender  <= dstIDP;
					o_RAMAddr_sender  <= local_base_addr + 2;
					o_RAMWE_sender  <= '1';
					receiving_state  <= STATE_DST_WRITE;
				when STATE_DST_WRITE  => 
					write_step <= "0011";
					if rx_ll_src_rdy = '1' then		
						payload_count  <= payload_count + 1;
						o_RAMAddr_sender <= o_RAMAddr_sender + 1;
						payload(23 downto 16)  <= rx_ll_data;
						receiving_state  <= STATE_RCV_3;
					end if;				
				when STATE_RCV_2  => 
					write_step <= "0100";
					if rx_ll_src_rdy = '1' then
						payload(23 downto 16)  <= rx_ll_data;
						payload_count  <= payload_count + 1;
						if rx_ll_eof = '1' then
							receiving_state  <= STATE_EOF;
							rx_ll_dst_rdy_local  <= '0';
							o_RAMWE_sender <= '1';
							o_RAMData_sender(8 to 15) <= rx_ll_data;
						else
							receiving_state  <= STATE_RCV_3;
						end if;
					end if;
				when STATE_RCV_3  => 
					write_step <= "0101";
					if rx_ll_src_rdy = '1' then
						payload(15 downto 8)  <= rx_ll_data;
						payload_count  <= payload_count + 1;
						if rx_ll_eof = '1' then
							receiving_state  <= STATE_EOF;
							rx_ll_dst_rdy_local  <= '0';
							o_RAMWE_sender <= '1';
							o_RAMData_sender(16 to 23) <= rx_ll_data;
						else
							receiving_state  <= STATE_RCV_4;
						end if;
					end if;
				when STATE_RCV_4  => 
					write_step <= "0110";
					if rx_ll_src_rdy = '1' then
						payload(7 downto 0)  <= rx_ll_data;
						o_RAMData_sender(24 to 31) <= rx_ll_data;
						o_RAMWE_sender <= '1';
						payload_count  <= payload_count + 1;
						if rx_ll_eof = '1' then
							receiving_state  <= STATE_EOF;
							rx_ll_dst_rdy_local  <= '0';
						else
							receiving_state  <= STATE_RCV_1;
						end if;
					end if;
				when STATE_RCV_1  => 
					write_step <= "0111";
					if rx_ll_src_rdy = '1' then
						payload(31 downto 24)  <= rx_ll_data;	
						payload_count <= payload_count + 1;
						o_RAMAddr_sender <= o_RAMAddr_sender + 1;
						if rx_ll_eof = '1' then
							receiving_state  <= STATE_EOF;
							o_RAMWE_sender <= '1';
							rx_ll_dst_rdy_local  <= '0';
							o_RAMData_sender(0 to 7) <= rx_ll_data;
						else
							receiving_state  <= STATE_RCV_2;
						end if;
					end if;					
				when STATE_EOF  => 
					write_step <= "1000";
					rx_ll_dst_rdy_local  <= '0'; 
					o_RAMAddr_sender <= local_base_addr;
					o_RAMData_sender <= meta_data & std_logic_vector(to_unsigned(payload_count, 16));
					o_RAMWE_sender <= '1';
					payload_count  <= payload_count + 12;
					packet_received  <= '1';
					receiving_state  <= STATE_DONE;					
				when STATE_DONE => 
					write_step <= "1111";
					packet_received  <= '1';
					rx_ll_dst_rdy_local  <= '0';
					receive_packet_done <= '1';
				when others  =>
					receiving_state <= STATE_DONE;
			end case;
		end if;
	end process;
	
	--count all tx sof packets
	test_counting : process(rx_ll_sof, rx_ll_src_rdy, rx_ll_dst_rdy_local, rx_packet_count, testing_state) is
	variable tmp : unsigned(31 downto 0);
	begin
	    rx_packet_count_next <= rx_packet_count;
    	    testing_state_next <= testing_state;
	    case testing_state is
        	when T_STATE_INIT =>
		    rx_packet_count_next <= (others => '0');
		    testing_state_next <= T_STATE_RCV;
		when T_STATE_RCV =>
		    if rx_ll_src_rdy = '1' and rx_ll_sof = '1' and rx_ll_dst_rdy_local = '1' then
			tmp := unsigned(rx_packet_count) + 1;
			rx_packet_count_next <= std_logic_vector(tmp);
		    end if;
		when others =>
		    testing_state_next <= T_STATE_INIT;
	    end case;
	end process;

	--count all tx eof packets
	tx_test_counting : process(rx_ll_eof, rx_ll_src_rdy, rx_ll_dst_rdy_local, tx_packet_count, tx_testing_state) is
	variable tmp : unsigned(31 downto 0);
	begin
	    tx_packet_count_next <= tx_packet_count;
    	    tx_testing_state_next <= tx_testing_state;
	    case tx_testing_state is
        	when T_STATE_INIT =>
		    tx_packet_count_next <= (others => '0');
		    tx_testing_state_next <= T_STATE_RCV;
		when T_STATE_RCV =>
		    if rx_ll_src_rdy = '1' and rx_ll_eof = '1' and rx_ll_dst_rdy_local = '1' then
			tmp := unsigned(tx_packet_count) + 1;
			tx_packet_count_next <= std_logic_vector(tmp);
		    end if;
		when others =>
		    tx_testing_state_next <= T_STATE_INIT;
	    end case;
	end process;

	--creates flipflops
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
	
	timeout_counter: process (clk,rst,timeout_counter_en) is
	begin
		if rst = '1' or timeout_counter_en = '0' then
			timer <= 0;
			timeout <= '0';
		elsif rising_edge(clk) then
			if timer < timeout_cycles then
				timeout <= '0';
				timer <= timer + 1;
			else
				timeout <= '1';
			end if;
		end if;
	end process;
	
	-- packet_manager keeps track of where in local RAM the next packet goes
	-- and if we have space for more before flushing the buffer to shared memory
	packet_manager: process (clk,rst,packet_manager_en) is
	variable base_addr_tmp : unsigned(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	begin
		if rst = '1' or packet_manager_en = '0' then
			local_base_addr <= (others => '0');
			packet_count <= 0;
			counter_state <= STATE_WAIT;
			receive_packet_en <= '0';
			timeout_counter_en <= '0';
			packet_manager_done <= '0';
		elsif rising_edge(clk) then
			receive_packet_en <= '0';
			packet_manager_done <= '0';
			timeout_counter_en <= '1';
			case counter_state is
				-- wait for receive_packet to do its job
				when STATE_WAIT =>
					receive_packet_en <= '1';
					if receive_packet_done = '1' then
						counter_state <= STATE_INCREMENT;
					end if;
				-- increment packet count and base address
				when STATE_INCREMENT =>
					if payload_count > 0 then
						packet_count <= packet_count + 1; --only increment if we got a packet of size > 0
					end if;
					--always round up to the next word if it does not evenly divide
					base_addr_tmp := unsigned(local_base_addr) + ((to_unsigned(payload_count, C_LOCAL_RAM_ADDRESS_WIDTH-1)+3)/4);
					local_base_addr <= std_logic_vector(base_addr_tmp);
					if base_addr_tmp + C_MAX_PACKET_LEN/4 < base_addr_tmp or base_addr_tmp + C_MAX_PACKET_LEN/4 >= unsigned(buffer_limit)/4 or timeout = '1' then --base_addr wrapped around so our buffer can't fit another packet of max size
						counter_state <= STATE_DONE;
					else
						counter_state <= STATE_WAIT;
					end if;
				when STATE_DONE =>
					timeout_counter_en <= '0';
					packet_manager_done <= '1';
				when others =>
					counter_state <= STATE_WAIT;
			end case;
		end if;
	end process;
	
	-- os and memory synchronisation state machine
	reconos_fsm: process (clk,rst,o_osif,o_memif,o_ram) is
		variable done  : boolean;
	begin
		if rst = '1' then
			osif_reset(o_osif);
			memif_reset(o_memif);
			ram_reset(o_ram);
			state <= STATE_INIT;
			done := False;
			base_addr <= (others => '0');
			buffer_limit <= (others => '1');
			len <= (others => '0');
			data_ready <= '0';
			base_addr_answer <= (others => '0');
			reconos_fsm_ready <= '0';
			reconos_step <= "000";
			packet_manager_en <= '0';
			timeout_cycles <= 0;
			timeout_ms <= (others => '0');
		elsif rising_edge(clk) then
			total_packet_len  <= std_logic_vector(to_unsigned(to_integer(unsigned(local_base_addr)), 22));
			data_ready <= '0';
			reconos_fsm_ready  <= '0';
			packet_manager_en <= '1';
			case state is
				-- get buffer size limit of packet buffer
				when STATE_INIT =>
					reconos_step <= "001";
					base_addr_answer <= (others => '0');
					osif_mbox_get(i_osif, o_osif, MBOX_RECV, buffer_limit, done);
					packet_manager_en <= '0';
					if done then
						state <= STATE_GET_TIMEOUT;
					end if;
				-- get timeout in ms
				when STATE_GET_TIMEOUT =>
					reconos_step <= "001";
					base_addr_answer <= (others => '0');
					osif_mbox_get(i_osif, o_osif, MBOX_RECV, timeout_ms, done);
					packet_manager_en <= '0';
					if done then
						timeout_cycles <= to_integer(unsigned(timeout_ms))*C_CYCLES_PER_MSECOND;
						state <= STATE_GET_LEN;
					end if;
				-- get nextmain memory address (packet buffer)
				when STATE_GET_LEN  => 
					reconos_step <= "101";
					packet_manager_en <= '0';
					osif_mbox_get(i_osif, o_osif, MBOX_RECV, base_addr, done);
					if done then state  <= STATE_WAIT; end if;
				-- wait for next packet
				when STATE_WAIT =>
					data_ready <= '1';
					reconos_step <= "010";
					reconos_fsm_ready  <= '1';
					if packet_manager_done = '1' then
						state <= STATE_WRITE;
						reconos_fsm_ready   <= '0';
					end if;
				-- copy packet from local ram to main memory
				when STATE_WRITE =>
					reconos_step <= "011";
					reconos_fsm_ready  <= '0';
					memif_write(i_ram, o_ram, i_memif, o_memif, X"00000000", base_addr, total_packet_len & "00", done); --extend to 24 bits and upshift
					if done then 
						state <= STATE_PUT;
					end if;					
				-- inform software, that a packet has been forwarded
				when STATE_PUT =>
					reconos_step <= "100";
					osif_mbox_put(i_osif, o_osif, MBOX_SEND, std_logic_vector(to_unsigned(packet_count,32)), ignore, done);
					if done then state <= STATE_GET_LEN; end if;
				-- thread exit
				when STATE_THREAD_EXIT =>
					reconos_step <= "111";
					packet_manager_en <= '0';
					osif_thread_exit(i_osif,o_osif);					
				when others =>
					state <= STATE_INIT;			
			end case;
		end if;
	end process;

end architecture;
