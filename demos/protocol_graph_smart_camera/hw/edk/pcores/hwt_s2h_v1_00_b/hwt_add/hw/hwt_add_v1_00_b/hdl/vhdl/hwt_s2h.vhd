library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library proc_common_v3_00_a;
use proc_common_v3_00_a.proc_common_pkg.all;

library reconos_v3_00_a;
use reconos_v3_00_a.reconos_pkg.all;

library ana_v1_00_a;
use ana_v1_00_a.anaPkg.all;


entity hwt_s2h is
	generic (
		destination	: std_logic_vector(5 downto 0)
	);
	port (
		-- OSIF FSL
		OSFSL_Clk       : in  std_logic;                 -- Synchronous clock
		OSFSL_Rst       : in  std_logic;
		OSFSL_S_Clk     : out std_logic;                 -- Slave asynchronous clock
		OSFSL_S_Read    : out std_logic;                 -- Read signal, requiring next available input to be read
		OSFSL_S_Data    : in  std_logic_vector(0 to 31); -- Input data
		OSFSL_S_Control : in  std_logic;                 -- Control Bit, indicating the input data are control word
		OSFSL_S_Exists  : in  std_logic;                 -- Data Exist Bit, indicating data exist in the input FSL bus
		OSFSL_M_Clk     : out std_logic;                 -- Master asynchronous clock
		OSFSL_M_Write   : out std_logic;                 -- Write signal, enabling writing to output FSL bus
		OSFSL_M_Data    : out std_logic_vector(0 to 31); -- Output data
		OSFSL_M_Control : out std_logic;                 -- Control Bit, indicating the output data are contol word
		OSFSL_M_Full    : in  std_logic;                 -- Full Bit, indicating output FSL bus is full
		
		-- FIFO Interface
		--FIFO32_S_Clk : out std_logic;
		--FIFO32_M_Clk : out std_logic;
		FIFO32_S_Data : in std_logic_vector(31 downto 0);
		FIFO32_M_Data : out std_logic_vector(31 downto 0);
		FIFO32_S_Fill : in std_logic_vector(15 downto 0);
		FIFO32_M_Rem : in std_logic_vector(15 downto 0);
		FIFO32_S_Rd : out std_logic;
		FIFO32_M_Wr : out std_logic;
		
		-- HWT reset
		rst           : in std_logic;

		switch_data_rdy		: in  std_logic;
		switch_data		: in  std_logic_vector(dataWidth downto 0);
		thread_read_rdy	 	: out std_logic;
		switch_read_rdy		: in  std_logic;
		thread_data		: out std_logic_vector(dataWidth downto 0);
		thread_data_rdy 	: out std_logic
	);

end hwt_s2h;

architecture implementation of hwt_s2h is
	type STATE_TYPE is ( STATE_INIT, STATE_GET_LEN, STATE_READ, STATE_WAIT, STATE_PUT, STATE_PUT2, STATE_THREAD_EXIT );

	-- PUT YOUR OWN COMPONENTS HERE

    -- END OF YOUR OWN COMPONENTS
	

    -- ADD YOUR CONSTANTS, TYPES AND SIGNALS BELOW

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
	constant C_LOCAL_RAM_SIZE          : integer := 2048;
	constant C_LOCAL_RAM_ADDRESS_WIDTH : integer := clog2(C_LOCAL_RAM_SIZE);
	constant C_LOCAL_RAM_SIZE_IN_BYTES : integer := 4*C_LOCAL_RAM_SIZE;

	type LOCAL_MEMORY_T is array (0 to C_LOCAL_RAM_SIZE-1) of std_logic_vector(31 downto 0);
	signal o_RAMAddr_sorter : std_logic_vector(0 to C_LOCAL_RAM_ADDRESS_WIDTH-1);
	signal o_RAMData_sorter : std_logic_vector(0 to 31);
	signal o_RAMWE_sorter   : std_logic;
	signal i_RAMData_sorter : std_logic_vector(0 to 31);

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

	type sending_state_t is (S_STATE_INIT, S_STATE_SOF, S_STATE_DATA, S_STATE_EOF, S_STATE_WAIT);
	signal sending_state		: sending_state_t;
	signal sending_state_next	: sending_state_t;


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

	type STATE_TYPE is (STATE_IDLE, STATE_READ_LEN_WAIT_A, STATE_WAIT_IDP_A, STATE_READ_LEN,
						STATE_SEND_SOF, STATE_SEND_SECOND, STATE_SEND_THIRD, STATE_SEND_FOURTH, 
						STATE_SEND_DATA_1, STATE_SEND_DATA_2, STATE_SEND_DATA_3, STATE_SEND_DATA_4,
						 STATE_SEND_EOF_1, STATE_SEND_EOF_2, STATE_SEND_EOF_3, STATE_SEND_EOF_4
	);

	signal state : STATE_TYPE;

begin
	

    -- PUT YOUR OWN INSTANCES HERE

	decoder_inst : packetDecoder
	port map (
		clk 	=> i_osif.clk,
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
		clk 				=> i_osif.clk,					
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
		noc_tx_globalAddress  		=> destination(5 downto 2), --"0000",--(others => '0'), --6 bits--(0:send it to hw/sw)		
		noc_tx_localAddress  		=> destination(1 downto 0), --"01",-- (others  => '0'), --2 bits		
		noc_tx_direction 	 	=> '0',		
		noc_tx_priority 	 	=> (others  => '0'),		
		noc_tx_latencyCritical  	=> '0',	
		noc_tx_srcIdp 			=> (others  => '0'),	
		noc_tx_dstIdp 			=> (others  => '0'),
		noc_tx_dst_rdy	 		=> tx_ll_dst_rdy
	);
	
    -- END OF YOUR OWN INSTANCES

	-- local dual-port RAM
	local_ram_ctrl_1 : process (OSFSL_Clk) is
	begin
		if (rising_edge(OSFSL_Clk)) then
			if (o_RAMWE_reconos = '1') then
				local_ram(conv_integer(unsigned(o_RAMAddr_reconos))) := o_RAMData_reconos;
			else
				i_RAMData_reconos <= local_ram(conv_integer(unsigned(o_RAMAddr_reconos)));
			end if;
		end if;
	end process;
			
	local_ram_ctrl_2 : process (OSFSL_Clk) is
	begin
		if (rising_edge(OSFSL_Clk)) then		
			if (o_RAMWE_sender = '1') then
				local_ram(conv_integer(unsigned(o_RAMAddr_sender))) := o_RAMData_sender;
			else
				i_RAMData_sender <= local_ram(conv_integer(unsigned(o_RAMAddr_sender)));
			end if;
		end if;
	end process;
	




	fsl_setup(
		i_osif,
		o_osif,
		OSFSL_Clk,
		OSFSL_Rst,
		OSFSL_S_Data,
		OSFSL_S_Exists,
		OSFSL_M_Full,
		OSFSL_M_Data,
		OSFSL_S_Read,
		OSFSL_M_Write,
		OSFSL_M_Control
	);
		
	memif_setup(
		i_memif,
		o_memif,
		OSFSL_Clk,
	--	FIFO32_S_Clk,
		FIFO32_S_Data,
		FIFO32_S_Fill,
		FIFO32_S_Rd,
	--	FIFO32_M_Clk,
		FIFO32_M_Data,
		FIFO32_M_Rem,
		FIFO32_M_Wr
	);
	
	ram_setup(
		i_ram,
		o_ram,
		o_RAMAddr_reconos_2,		
		o_RAMData_reconos,
		i_RAMData_reconos,
		o_RAMWE_reconos
	);
	
	
    -- PUT YOUR OWN PROCESSES HERE
	
	--we are always ready and don't send any packets

	rx_ll_dst_rdy <= rx_ll_dst_rdy_local;
	rx_ll_dst_rdy_local <= '1';

	--for now we send everything to destination 0
	destination <= (others => '0');

	--TODO: copy the state machine sort_proc from bubble_sorter here and use its structure!
	sending_from_ram : process (clk, reset)
	begin
		if reset = '1' then

		elsif rising_edge(clk) then
			tx_ll_data <= (others => '0');
			tx_ll_sof <= '0';
			tx_ll_eof <= '0';
			tx_ll_src_rdy <= '1';
		--default assignement
		case state is
			when STATE_IDLE =>
				tx_ll_src_rdy <= '0';
				ram_addr <= (others => '0'); -- ADDRESS OF LEN is always 0
				if data_ready = '1' then
					state <= STATE_READ_LEN_WAIT_A;
				end if;
			when STATE_READ_LEN_WAIT_A =>
				tx_ll_src_rdy <= '0';
				ram_addr <= ram_addr + 1;
				state <= STATE_WAIT_IDP_A;
			when STATE_WAIT_IDP_A =>
				tx_ll_src_rdy <= '0';
				ram_addr <= ram_addr + 1;
				state <= STATE_READ_LEN;
			when STATE_READ_LEN =>
				tx_ll_src_rdy <= '0';
				total_packet_len <= i_RAM_DATA;	--length is ready
				state <= STATE_SEND_SOF;
			when STATE_SEND_SOF =>
				tx_data_word <= i_RAM_DATA;
				tx_ll_data <= i_RAM_DATA(31 downto 24);
				tx_ll_sof <= '1';
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_SECOND;
				end if;
			when STATE_SEND_SECOND => 
				tx_ll_data <= tx_data_word(23 downto 16);
				ram_addr <= ram_addr + 1;
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_THIRD;
				end if;
			when STATE_SEND_THIRD =>
				tx_ll_data <= tx_data_word(15 downto 8);
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_FOURTH;
				end if;
			when STATE_SEND_FOURTH =>
				tx_ll_data <= tx_data_word(7 downto 0);
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_DATA_1;
					payload_count <= 4;
				end if;
			when STATE_SEND_DATA_1 =>
				tx_data_word <= i_RAM_DATA;
				tx_ll_data <= i_RAM_DATA(31 downto 24);
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_DATA_2;
				end if;
			when STATE_SEND_DATA_2 =>
				tx_ll_data <= tx_data_word(23 downto 16);
				ram_addr <= ram_addr + 1;
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_DATA_3;
				end if;
			when STATE_SEND_DATA_3 =>
				tx_ll_data <= tx_data_word(15 downto 8);
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_DATA_4;
				end if;
			when STATE_SEND_DATA_4 =>
				tx_ll_data <= tx_data_word(7 downto 0);
				if tx_ll_dst_rdy = '1' then
					if (payload_count + 4) = total_packet_len then
						state <= STATE_SEND_EOF_1;
					else
						payload_count <= payload_count + 4;
						state <= STATE_SEND_DATA_1;
					end if;		
				end if;
			when STATE_SEND_EOF_1 => 
				tx_data_word <= i_RAM_DATA;
				tx_ll_data <= i_RAM_DATA(31 downto 24);
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_EOF_2;
				end if;
			when STATE_SEND_EOF_2 => 
				tx_ll_data <= tx_data_word(23 downto 16);
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_EOF_3;
				end if;
			when STATE_SEND_EOF_3 =>
				tx_ll_data <= tx_data_word(15 downto 8);
				if tx_ll_dst_rdy = '1' then
					state <= STATE_SEND_EOF_4;
				end if;
			when STATE_SEND_EOF_4 =>
				tx_ll_data <= tx_data_word(7 downto 0);
				tx_ll_eof <= '1';
				if tx_ll_dst_rdy = '1' then
					state <= STATE_IDLE;
					packets_sent <= '1';
				end if;
			when others => 
				state <= STATE_IDLE;
		end case;	
		end if;
	end process;


--	sending : process (tx_ll_dst_rdy, sending_state, data_ready )
--	begin
--		sending_state_next  <= sending_state;
--		payload_count_next  <= payload_count;
--		tx_ll_data  <= x"00";
--		tx_ll_src_rdy  <= '0';
--		tx_ll_sof  <=  '0';
--		tx_ll_eof  <= '0';
--		case sending_state is
--		when S_STATE_INIT  =>
--			if data_ready = '1' then
--				sending_state_next  <= S_STATE_START_BATCH;
--			end if;
--		when S_STATE_START_BATCH =>
--			--read packet len
--			packet_addr <= 0;
--			sending_state_next <= S_STATE_WAIT_PACKET_LEN;
--
--		when S_STATE_WAIT_PACKET_LEN =>
--			packet_add <= 1; --second word
--			sending_state_next <= S_STATE_GET_PACKET_LEN;
--			
--		when S_STATE_GET_PACKET_LEN =>
--			packet_len
--
--		when S_STATE_SOF  => 
--			tx_ll_src_rdy  <= '1';
--			tx_ll_data  <= x"AB";
--			tx_ll_sof  <= '1';
--			if tx_ll_dst_rdy = '1' then
--				sending_state_next  <= S_STATE_DATA;
--			end if;
--		when S_STATE_DATA  =>
--			tx_ll_src_rdy  <= '1';
--			tx_ll_data  <= x"FF";
--			if tx_ll_dst_rdy = '1' then
--				payload_count_next  <= payload_count + 1;
--				if payload_count = 10 then
--					sending_state_next  <= S_STATE_EOF;
--					payload_count_next  <= 0;
--				end if;
--			end if;
--		when S_STATE_EOF  => 
--			tx_ll_src_rdy  <=  '1';
--			tx_ll_data  <= x"BA";
--			tx_ll_eof  <= '1';
--			if tx_ll_dst_rdy = '1' then
--				sending_state_next  <= S_STATE_WAIT;
--			end if;
--		when S_STATE_WAIT =>
--			payload_count_next <= payload_count + 1;
--			if payload_count = 1000 then
--				sending_state_next <= S_STATE_INIT;
--				payload_count_next <= 0;
--			end if;
--		when others  =>
--			sending_state_next  <= S_STATE_INIT;
--		end case;
--	end process; 
--	end generate;


	--count all rx packets
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

	--count all tx packets
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


	--creates flipflops
	memzing: process(i_osif.clk, rst) is
	begin
	    if rst = '1' then
	        rx_packet_count <= (others => '0');
	        testing_state <= T_STATE_INIT;
     		tx_packet_count <= (others => '0');
	        tx_testing_state <= T_STATE_INIT;
		sending_state <= S_STATE_INIT;
		payload_count <= 0;
	    elsif rising_edge(i_osif.clk) then
	        rx_packet_count <= rx_packet_count_next;
	        testing_state <= testing_state_next;
  		tx_packet_count <= tx_packet_count_next;
	        tx_testing_state <= tx_testing_state_next;
		sending_state <= sending_state_next;
		payload_count <= payload_count_next;
	    end if;
	end process;


	-- END OF YOUR OWN PROCESSES
 -- ADJUST THE RECONOS_FSM TO YOUR NEEDS.		
	-- os and memory synchronisation state machine
	reconos_fsm: process (i_osif.clk,rst,o_osif,o_memif,o_ram) is
		variable done  : boolean;
	begin
		if rst = '1' then
			osif_reset(o_osif);
			memif_reset(o_memif);
			state <= STATE_INIT;


            -- RESET YOUR OWN SIGNALS HERE

		elsif rising_edge(i_osif.clk) then
			data_ready <= '0';
			case state is

                -- EXAMPLE STATE MACHINE - ADD YOUR STATES AS NEEDED

				-- Get some data
				when STATE_INIT =>
					osif_mbox_get(i_osif, o_osif, MBOX_RECV, base_addr, done);
					if done then
						state <= STATE_GET_LEN;
						base_addr <= base_addr(31 downto 2) & "00";
					end if;
				
				when STATE_GET_LEN =>
					osif_mbox_get(i_osif, o_osif, MBOX_RECV, len, done);
					if done then
						state <= STATE_READ;
					end if;

				when STATE_READ =>
					zero := (others => '0');
					memif_read(i_ram,o_ram,i_memif,o_memif, base_addr, x"00000000", len,done);
					if done then
						state <= STATE_WAIT;
					end if;

				when STATE_WAIT =>
					data_ready <= '1';
					if packets_sent = '1' then
						state <= STATE_PUT;
					end if;
				
				-- Echo the data
				when STATE_PUT =>
					osif_mbox_put(i_osif, o_osif, MBOX_SEND, rx_packet_count, ignore, done);
					if done then state <= STATE_PUT2; end if;
				
				when STATE_PUT2 =>
					osif_mbox_put(i_osif, o_osif, MBOX_SEND, tx_packet_count, ignore, done);
					if done then state <= STATE_GET_LEN; end if;

				-- thread exit
				when STATE_THREAD_EXIT =>
					osif_thread_exit(i_osif,o_osif);
			
			end case;
		end if;
	end process;



end architecture;
