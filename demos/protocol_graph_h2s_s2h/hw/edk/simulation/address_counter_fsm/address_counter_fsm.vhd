library ieee;
use ieee.std_logic_1164.all;
--use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;
use ieee.numeric_std.all;


entity address_counter_fsm is
	generic (
		C_LOCAL_RAM_SIZE : integer := 2048;
		C_LOCAL_RAM_ADDRESS_WIDTH : integer := 11;
		C_LOCAL_RAM_SIZE_IN_BYTES : integer := 8192;
		C_MAX_PACKET_LEN : integer := 1500;
		C_MIN_PACKET_LEN : integer := 64
	);
	port (
		rst                   : in std_logic;
		clk                   : in std_logic;
		payload_count         : in integer range 0 to C_MAX_PACKET_LEN;
		packet_counter_en     : in std_logic;
		receiving_to_ram_done : in std_logic;
		receiving_to_ram_en   : out std_logic;
		packet_counter_done   : out std_logic;
		local_base_addr_out   : out std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
		packet_count_out      : out integer range 0 to (C_LOCAL_RAM_SIZE_IN_BYTES/C_MIN_PACKET_LEN + 1)
	);

end address_counter_fsm;

architecture implementation of address_counter_fsm is

	type COUNTER_STATE_T is (STATE_WAIT, STATE_INCREMENT, STATE_DONE);
	signal counter_state : COUNTER_STATE_T;
	
	signal packet_count      : integer range 0 to (C_LOCAL_RAM_SIZE_IN_BYTES/C_MIN_PACKET_LEN + 1);
	signal local_base_addr   : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);

begin
	
	local_base_addr_out <= local_base_addr;
	packet_count_out <= packet_count;
	-- packet_counter_fsm keeps track of where in local RAM the next packet goes
	-- and if we have space for more before flushing the buffer to shared memory
	packet_counter_fsm: process (clk,rst,packet_counter_en) is
	variable base_addr_tmp : unsigned(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	begin
		if rst = '1' or packet_counter_en = '0' then
			local_base_addr <= (others => '0');
			packet_count <= 0;
			counter_state <= STATE_WAIT;
			receiving_to_ram_en <= '0';
			packet_counter_done <= '0';
		elsif rising_edge(clk) then
			receiving_to_ram_en <= '0';
			packet_counter_done <= '0';
			case counter_state is
				-- wait for receiving_to_ram to do its job
				when STATE_WAIT =>
					receiving_to_ram_en <= '1';
					if receiving_to_ram_done = '1' then
						counter_state <= STATE_INCREMENT;
					end if;
				-- increment packet count and base address
				when STATE_INCREMENT =>
					packet_count <= packet_count + 1;
					--always round up to the next word if it does not evenly divide
					base_addr_tmp := unsigned(local_base_addr) + ((to_unsigned(payload_count,C_LOCAL_RAM_ADDRESS_WIDTH)+3)/4);
					local_base_addr <= std_logic_vector(base_addr_tmp);
					if base_addr_tmp + C_MAX_PACKET_LEN/4 < base_addr_tmp then --base_addr wrapped around so our buffer can't fit another packet of max size
						counter_state <= STATE_DONE;
					else
						counter_state <= STATE_WAIT;
					end if;
				when STATE_DONE =>
					packet_counter_done <= '1';
				when others =>
					counter_state <= STATE_WAIT;
			end case;
		end if;
	end process;

end architecture;
