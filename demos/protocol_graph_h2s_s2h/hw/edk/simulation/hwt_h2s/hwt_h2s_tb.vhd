			--------------------------------------------------------------------------------
-- Company: 
-- Eng		ineer:
	--
	-- Create Date:   11:24:17 01/20/2012
-- Design Name:   
-- Module Name:   hwt_h2s_tb.vhd
-- Project Name:  
-- Target Device:  
-- Tool versions:  
-- Description:   
-- 
-- VHDL Test Bench Created by ISE for module: hwt_s2h
-- 
-- Dependencies:
-- 
-- Revision:
-- Revision 0.01 - File Created
-- Additional Comments:
--
-- Notes: 
-- This testbench has been automatically generated using types std_logic and
-- std_logic_vector for the ports of the unit under test.  Xilinx recommends
-- that these types always be used for the top-level I/O of a design in order
-- to guarantee that the testbench will bind correctly to the post-implementation 
-- simulation model.
--------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

LIBRARY fsl_v20_v2_11_f;
USE fsl_v20_v2_11_f.ALL;

LIBRARY fifo32_v1_00_a;
USE fifo32_v1_00_a.ALL;
 
-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--USE ieee.numeric_std.ALL;
 
ENTITY hwt_h2s_tb IS
END hwt_h2s_tb;
 
ARCHITECTURE behavior OF hwt_h2s_tb IS 

	-- HWT signals ----------------------------------------------------------------
	-- OS2HWT FSL
	signal OSFSL_S_Data : std_logic_vector(0 to 31) := (others => '0');
	signal OSFSL_S_Read : std_logic;
	signal OSFSL_S_Exists : std_logic := '0';

	-- HWT2OS FSL
	signal OSFSL_M_Full : std_logic := '0';
	signal OSFSL_M_Write : std_logic;
	signal OSFSL_M_Data : std_logic_vector(0 to 31);

	-- HWT2MEM FIFO32
	signal FIFO32_M_Data : std_logic_vector(31 downto 0);
	signal FIFO32_M_Rem : std_logic_vector(15 downto 0) := (others => '0');
	signal FIFO32_M_Wr : std_logic;

	-- MEM2HWT FIFO32
	signal FIFO32_S_Data : std_logic_vector(31 downto 0) := (others => '0');
	signal FIFO32_S_Fill : std_logic_vector(15 downto 0) := (others => '0');
	signal FIFO32_S_Rd : std_logic;

	-- Microblaze -----------------------------------------------------------------	
	signal MB_S_Data : std_logic_vector(31 downto 0);
	signal MB_S_Read : std_logic;
	signal MB_S_Exists : std_logic;
	signal MB_M_Data : std_logic_vector(31 downto 0);
	signal MB_M_Write : std_logic := '0';
	signal MB_M_Full : std_logic;

	-- Memory
	signal MEM_M_Data : std_logic_vector(31 downto 0);
	signal MEM_M_Rem  : std_logic_vector(15 downto 0);
	signal MEM_M_Wr   : std_logic;

	signal MEM_S_Data : std_logic_vector(31 downto 0);
	signal MEM_S_Fill : std_logic_vector(15 downto 0);
	signal MEM_S_Rd   : std_logic;

	-- Clock and reset
	constant clk_period : time := 10 ns;
	signal clk : std_logic;
	signal rst : std_logic := '0';

	-- ram interface
	signal ram_addr : std_logic_vector(31 downto 0);
	signal ram_addr_delay : std_logic_vector(31 downto 0);
	signal ram_di   : std_logic_vector(31 downto 0);
	signal ram_do   : std_logic_vector(31 downto 0);
	signal ram_we   : std_logic;

	-- NoC interface
	signal switch_data_rdy	: std_logic;
	signal switch_data	: std_logic_vector(8 downto 0);
	signal thread_read_rdy	: std_logic;
	signal switch_read_rdy	: std_logic;
	signal thread_data	: std_logic_vector(8 downto 0);
	signal thread_data_rdy 	: std_logic;
	
	constant PAYLOAD_LENGTH : integer := 128;
	constant PAYLOAD_LENGTH2 : integer := 65;

	type MEMSTATE_T is (MEMSTATE_IDLE, MEMSTATE_READ_CMD, MEMSTATE_READ_ADDR, MEMSTATE_WRITE, MEMSTATE_COPY_TO_RAM,
	                    MEMSTATE_READ, MEMSTATE_COPY_FROM_RAM);
	
	signal memstate : MEMSTATE_T;
	signal state_g : std_logic_vector (15 downto 0);
	signal state_g_next : std_logic_vector (15 downto 0);
	signal counter : std_logic_vector (15 downto 0);
	signal counter_next : std_logic_vector (15 downto 0);
	signal packet_count : integer range 0 to 128;
	signal switch : std_logic := '0';
	
BEGIN

	--packet_gen_proc : process(state_g,counter,counter_next,thread_read_rdy)
	packet_gen_proc : process(state_g,counter,counter_next,thread_read_rdy)
	begin
		if rst = '1' then
			packet_count <= 0;
		end if;
		state_g_next <= state_g + 1;
		counter_next <= (others=>'0');
		packet_count <= packet_count;
		case state_g is
			-- send NoC header
			when X"0000" => 
				switch_data_rdy <= '0';
				switch_data <= "0"&X"00";
			when X"0001" => -- switch_addr(4b), block_addr (2b), prio (2b) -> will be ignored by h2s
				switch_data_rdy <= '1';
				switch_data <= "0"&X"00";
			when X"0002" => -- direction (1), latency-critical (1b), reserved (6b) -> will be ignored by h2s
				switch_data <= "0"&X"00";
			when X"0003" => -- src idp (4 bytes)
				switch_data <= "0"&X"00";
			when X"0004" =>
				switch_data <= "0"&X"00";
			when X"0005" =>
				switch_data <= "0"&X"00";
			when X"0006" =>
				switch_data <= "0"&X"06";
			when X"0007" => -- dst idp (4 bytes)
				switch_data <= "0"&X"00";
			when X"0008" =>
				switch_data <= "0"&X"00";
			when X"0009" =>
				switch_data <= "0"&X"00";
			when X"000A" =>
				switch_data <= "0"&X"07";
			when X"000B" => -- payload length
				if (switch='0') then
					switch_data <= "0"&X"AB";
					if (counter_next < (PAYLOAD_LENGTH-1)) then
						state_g_next <= state_g;
					else
						state_g_next <= state_g + 1;
					end if;
				else
					switch_data <= "0"&X"CD";
					if (counter_next < (PAYLOAD_LENGTH2-1)) then
						state_g_next <= state_g;
					else
						state_g_next <= state_g + 1;
					end if;
				end if;
				if (thread_read_rdy='1') then
					counter_next <= counter + 1;
				else
					counter_next <= counter;
				end if;
			when X"000C" => -- final word
				if (switch='0') then
					switch_data <= "1"&X"AF";
				else
					switch_data <= "1"&X"CF";
				end if;
			when X"000D" => -- switch between "AB" and "CD" packets
				switch <= not switch;
				packet_count <= packet_count + 1;
			when X"000E" => 
				if packet_count > 300 then --stop sending packets after the fourth one
					state_g_next <= X"000E";
				end if;
				switch_data <= "0"&X"00";
				switch_data_rdy <= '0';
			when X"000F" => -- send next packet
				switch_data <= "0"&X"00";
				switch_data_rdy <= '1';
				state_g_next <= X"0003";
			when others =>
				state_g_next <= state_g;
		end case;	
	end process;
	
	
	mem_proc : process(clk,rst)
	begin
		if (rst='1') then
			state_g <= (others=>'0');
			counter <= (others=>'0');
		elsif (rising_edge(clk)) then
			counter <= counter_next;
			if (thread_read_rdy='1') then
				state_g <= state_g_next;
			else
				state_g <= state_g;
			end if;
		end if;
	end process;
 
	-- RECONOS OSIF stimulus
	stim_proc: process
	begin
			MB_M_Write <= '0';	
			-- return value for mbox_get
			-- set buffer size (in bytes, should be word-aligned)
			wait for clk_period*100;
			MB_M_Write <= '1';
			MB_M_Data <= x"00000800"; -- 2KB
			wait for clk_period;
			MB_M_Write <= '0';
			MB_M_Write <= '0';	
			-- return value for mbox_get
			-- set timeout (in ms)
			wait for clk_period*100;
			MB_M_Write <= '1';
			MB_M_Data <= x"00000010"; -- 16ms
			wait for clk_period;
			MB_M_Write <= '0';
		loop
			MB_M_Write <= '0';	
			-- return value for mbox_get
			-- set addr (in bytes, should be word-aligned)
			wait for clk_period*100;
			MB_M_Write <= '1';
			MB_M_Data <= x"00000000";
			wait for clk_period;
			MB_M_Write <= '0';
			
			-- return for mbox_put command (value is ignored)
			wait for clk_period*100;
			MB_M_Write <= '1';
			MB_M_Data <= x"00000000";
			wait for clk_period;
			MB_M_Write <= '0';
		end loop;
		
	end process;
	
		-- set reset signal
	rst_proc : process
	begin
		rst <= '1';
		wait for 105 ns;	
		rst <= '0';
		wait;
	end process;

	-- generate clock signal
	clk_process :process
	begin
		clk <= '0';
		wait for clk_period/2;
		clk <= '1';
		wait for clk_period/2;
	end process;
	
	-- simulate main memory interface
	memfifo_proc : process(clk,rst)
		variable cmd  : std_logic_vector(7 downto 0);
		variable addr : std_logic_vector(31 downto 0);
		variable len  : std_logic_vector(21 downto 0);
	begin
		if rst = '1' then
			memstate <= MEMSTATE_IDLE;
		elsif rising_edge(clk) then
			MEM_S_Rd <= '0';
			MEM_M_Wr <= '0';
			ram_we <= '0';
			case memstate is
				when MEMSTATE_IDLE =>
					if 1 < MEM_S_Fill then
						MEM_S_Rd <= '1';
						memstate <= MEMSTATE_READ_CMD;
					end if;
					
				when MEMSTATE_READ_CMD =>
					cmd := MEM_S_Data(31 downto 24);
					len := MEM_S_Data(23 downto  2);
					MEM_S_Rd <= '1';
					memstate <= MEMSTATE_READ_ADDR;
						
				when MEMSTATE_READ_ADDR =>
					ram_addr <= "00" & MEM_S_Data(31 downto 2);
					ram_addr_delay <= "00" & MEM_S_Data(31 downto 2);
					if cmd = x"80" then
						memstate <= MEMSTATE_WRITE;
					else
						memstate <= MEMSTATE_READ;
					end if;
					
				when MEMSTATE_WRITE =>
					if MEM_S_Fill >= len then
						MEM_S_Rd <= '1';
						memstate <= MEMSTATE_COPY_TO_RAM;
					end if;
					
				when MEMSTATE_COPY_TO_RAM =>
					if len = 0 then
						memstate <= MEMSTATE_IDLE;
					else
						if len > 1 then
							MEM_S_Rd <= '1';
						end if;
						ram_addr_delay <= ram_addr_delay + 1;
						ram_addr <= ram_addr_delay;
						ram_di <= MEM_S_Data;
						ram_we <= '1';
						len := len - 1;
					end if;
				
				when MEMSTATE_READ =>
					if MEM_M_Rem >= len then
						memstate <= MEMSTATE_COPY_FROM_RAM;
					end if;
				
				when MEMSTATE_COPY_FROM_RAM =>
					if len = 0 then
						memstate <= MEMSTATE_IDLE;
					else
						MEM_M_Wr <= '1';
						MEM_M_Data <= ram_do;
						ram_addr <= ram_addr + 1;
						len := len - 1;
					end if;
			end case;
		end if;
	end process;
 
	-- Instantiate the Unit Under Test (UUT)
	uut: entity work.hwt_h2s PORT MAP (
		OSFSL_S_Read    => OSFSL_S_Read,
		OSFSL_S_Data    => OSFSL_S_Data,
		OSFSL_S_Control => '0',
		OSFSL_S_Exists  => OSFSL_S_Exists, 
		OSFSL_M_Write   => OSFSL_M_Write,
		OSFSL_M_Data    => OSFSL_M_Data, 
		OSFSL_M_Control => open,
		OSFSL_M_Full    => OSFSL_M_Full,
		FIFO32_S_Data   => FIFO32_S_Data,
		FIFO32_M_Data   => FIFO32_M_Data,
		FIFO32_S_Fill   => FIFO32_S_Fill,
		FIFO32_M_Rem    => FIFO32_M_Rem,
		FIFO32_S_Rd     => FIFO32_S_Rd,
		FIFO32_M_Wr     => FIFO32_M_Wr, 
		clk             => clk,       
		rst             => rst,
		switch_data_rdy	=> switch_data_rdy,
		switch_data     => switch_data,
		thread_read_rdy => thread_read_rdy,
		switch_read_rdy => switch_read_rdy,
		thread_data     => thread_data,
		thread_data_rdy => thread_data_rdy   
	);


	-- instantiate main memory
	mem_i : entity work.memory
	port map (
		clk  => clk,
		rst  => rst,
		addr => ram_addr,
		di   => ram_di,
		do   => ram_do,
		we   => ram_we
	);

	
	-- instantiate FSLs
	fsl_a : entity fsl_v20_v2_11_f.fsl_v20
		generic map (
			C_EXT_RESET_HIGH => 1,
			C_ASYNC_CLKS => 0,
			C_IMPL_STYLE => 0,
			C_USE_CONTROL => 0,
			C_FSL_DWIDTH => 32,
			C_FSL_DEPTH => 16,
			C_READ_CLOCK_PERIOD => 0
	)
	port map (
		FSL_Clk => clk,
		SYS_Rst => rst,
		FSL_Rst => open,
		FSL_M_Clk => clk,
		FSL_M_Data => OSFSL_M_Data,
		FSL_M_Control => '0',
		FSL_M_Write => OSFSL_M_Write,
		FSL_M_Full => OSFSL_M_Full,
		FSL_S_Clk => clk,
		FSL_S_Data => MB_S_Data,
		FSL_S_Control => open,
		FSL_S_Read => MB_S_Read,
		FSL_S_Exists => MB_S_Exists,
		FSL_Full => open,
		FSL_Has_Data => open,
		FSL_Control_IRQ => open
	);

	fsl_b : entity fsl_v20_v2_11_f.fsl_v20
	generic map (
		C_EXT_RESET_HIGH => 1,
		C_ASYNC_CLKS => 0,
		C_IMPL_STYLE => 0,
		C_USE_CONTROL => 0,
		C_FSL_DWIDTH => 32,
		C_FSL_DEPTH => 16,
		C_READ_CLOCK_PERIOD => 0
	)
	port map (
		FSL_Clk => clk,
		SYS_Rst => rst,
		FSL_Rst => open,
		FSL_M_Clk => clk,
		FSL_M_Data => MB_M_Data,
		FSL_M_Control => '0',
		FSL_M_Write => MB_M_Write,
		FSL_M_Full => MB_M_Full,
		FSL_S_Clk => clk,
		FSL_S_Data => OSFSL_S_Data,
		FSL_S_Control => open,
		FSL_S_Read => OSFSL_S_Read,
		FSL_S_Exists => OSFSL_S_Exists,
		FSL_Full => open,
		FSL_Has_Data => open,
		FSL_Control_IRQ => open
	);
	 
	-- instantiate FIFO32s
	fifo32_a : entity fifo32_v1_00_a.fifo32
	generic map (
		C_FIFO32_DEPTH => 1024
	)
	port map (
		Rst => Rst,
		FIFO32_S_Clk => clk,
		FIFO32_S_Data => MEM_S_Data,
		FIFO32_S_Rd => MEM_S_Rd,
		FIFO32_S_Fill => MEM_S_Fill,
		FIFO32_M_Clk => clk,
		FIFO32_M_Data => FIFO32_M_Data,
		FIFO32_M_Wr => FIFO32_M_Wr,
		FIFO32_M_Rem => FIFO32_M_Rem
	);

	fifo32_b : entity fifo32_v1_00_a.fifo32
	generic map (
		C_FIFO32_DEPTH => 1024
	)
	port map (
		Rst => Rst,
		FIFO32_S_Clk => clk,
		FIFO32_S_Data => FIFO32_S_Data,
		FIFO32_S_Rd => FIFO32_S_Rd,
		FIFO32_S_Fill => FIFO32_S_Fill,
		FIFO32_M_Clk => clk,
		FIFO32_M_Data => MEM_M_Data,
		FIFO32_M_Wr => MEM_M_Wr,
		FIFO32_M_Rem => MEM_M_Rem
	);

END;

