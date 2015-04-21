--------------------------------------------------------------------------------
-- Company: 
-- Engineer:
--
-- Create Date:   14:32:53 04/21/2015
-- Design Name:   
-- Module Name:   /home/dave/ETH/SemesterProject/xilinx/work/git/reconos/demos/protocol_graph_h2s_s2h/hw/edk/simulation/address_counter_fsm/address_counter_tb.vhd
-- Project Name:  address_counter_fsm
-- Target Device:  
-- Tool versions:  
-- Description:   
-- 
-- VHDL Test Bench Created by ISE for module: address_counter_fsm
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
LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;
 
-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
--USE ieee.numeric_std.ALL;
 
ENTITY address_counter_tb IS
END address_counter_tb;
 
ARCHITECTURE behavior OF address_counter_tb IS 
 
    -- Component Declaration for the Unit Under Test (UUT)
 
    COMPONENT address_counter_fsm
    PORT(
         rst : IN  std_logic;
         clk : IN  std_logic;
         payload_count : IN  integer range 0 to 1500;
         packet_counter_en : IN  std_logic;
         receiving_to_ram_done : IN  std_logic;
         receiving_to_ram_en : OUT  std_logic;
         packet_counter_done : OUT  std_logic;
         local_base_addr_out : OUT  std_logic_vector(0 to 10);
         packet_count_out : OUT  integer range 0 to 128
        );
    END COMPONENT;
    

   --Inputs
   signal rst : std_logic := '0';
   signal clk : std_logic := '0';
   signal payload_count : integer range 0 to 1500;
   signal packet_counter_en : std_logic := '0';
   signal receiving_to_ram_done : std_logic := '0';

 	--Outputs
   signal receiving_to_ram_en : std_logic;
   signal packet_counter_done : std_logic;
   signal local_base_addr_out : std_logic_vector(0 to 10);
   signal packet_count_out : integer range 0 to 128;

   -- Clock period definitions
   constant clk_period : time := 10 ns;
 
BEGIN
 
	-- Instantiate the Unit Under Test (UUT)
   uut: address_counter_fsm PORT MAP (
          rst => rst,
          clk => clk,
          payload_count => payload_count,
          packet_counter_en => packet_counter_en,
          receiving_to_ram_done => receiving_to_ram_done,
          receiving_to_ram_en => receiving_to_ram_en,
          packet_counter_done => packet_counter_done,
          local_base_addr_out => local_base_addr_out,
          packet_count_out => packet_count_out
        );

   -- Clock process definitions
   clk_process :process
   begin
		clk <= '0';
		wait for clk_period/2;
		clk <= '1';
		wait for clk_period/2;
   end process;
 

   -- Stimulus process
   stim_proc: process
   begin		
      -- hold reset state for 100 ns.
		rst <= '1';
      wait for 100 ns;
		packet_counter_en <= '0';
		receiving_to_ram_done <='0';
		rst <= '0';

      wait for clk_period*2;
		wait for 5 ns; --introduce some skew
		packet_counter_en <= '1';
      -- send 8 packages of size I*64+I bytes and assume it took I clock cycles to receive the packet
		-- this will use 2352 bytes in total if all packages are padded so the next one in line will be word aligned
		for I in 1 to 8 loop
			if receiving_to_ram_en='0' then
				wait until receiving_to_ram_en='1';
			end if;
			
			-- wait for packet to be received
			wait for clk_period*I;
			payload_count <= I*64+I;
			receiving_to_ram_done <= '1';
			wait until receiving_to_ram_en='0';
			wait for clk_period;
			receiving_to_ram_done <= '0';
			payload_count <= 0;
			wait for 2ns;		
		end loop;
		
		-- now send as many packets of 1500 bytes as it takes so the buffer can't fit another, each taking 5 clock cycles
		while packet_counter_done='0' loop
			if receiving_to_ram_en='0' then
				wait until receiving_to_ram_en='1';
			end if;
			
			-- wait for packet to be received
			wait for clk_period*5;
			payload_count <= 1500;
			receiving_to_ram_done <= '1';
			wait until receiving_to_ram_en='0';
			wait for clk_period;
			receiving_to_ram_done <= '0';
			payload_count <= 0;
			wait for 2ns;
		end loop;
		
		packet_counter_en <= '0';
		wait for clk_period;
		
      wait;
   end process;

END;
