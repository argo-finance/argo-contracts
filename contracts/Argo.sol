pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./owner/Operator.sol";
import "./lib/SafeMath8.sol";
import "./interfaces/IOracle.sol";

contract Argo is ERC20Burnable, Operator {
    using SafeMath8 for uint8;
    using SafeMath for uint256;

    // Initial distribution for the first 24h genesis pools
    uint256 public constant INITIAL_GENESIS_POOL_DISTRIBUTION = 27500 ether;
    // Distribution for initial offering
    uint256 public constant INITIAL_OFFERING_DISTRIBUTION = 11000 ether;

    // Have the rewards been distributed to the pools
    bool public rewardPoolDistributed = false;
    bool public initialOfferingDistributed = false;

    /* ================= Taxation =============== */
    // Address of the Oracle
    address public argoOracle;

    address private _operator;

    /**
     * @notice Constructs the ARGO ERC-20 contract.
     */
    constructor() public ERC20("ARGO", "ARGO") {
        // Mints 1 ARGO to contract creator for initial pool setup
        _operator = msg.sender;
        emit OperatorTransferred(address(0), _operator);

        _mint(msg.sender, 1 ether);
    }

    function _getArgoPrice() internal view returns (uint256 _argoPrice) {
        try IOracle(argoOracle).consult(address(this), 1e18) returns (uint144 _price) {
            return uint256(_price);
        } catch {
            revert("Argo: failed to fetch ARGO price from Oracle");
        }
    }

    function setArgoOracle(address _argoOracle) public onlyOperator {
        require(_argoOracle != address(0), "oracle address cannot be 0 address");
        argoOracle = _argoOracle;
    }

    /**
     * @notice Operator mints ARGO to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of ARGO to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOperator {
        super.burnFrom(account, amount);
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), allowance(sender, _msgSender()).sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function distributeInitialOffering(
        address _offeringContract
    ) external onlyOperator {
        require(_offeringContract != address(0), "!_offeringContract");
        require(!initialOfferingDistributed, "only distribute once");

        _mint(_offeringContract, INITIAL_OFFERING_DISTRIBUTION);
        initialOfferingDistributed = true;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(
        address _genesisPool
    ) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_genesisPool != address(0), "!_genesisPool");
        rewardPoolDistributed = true;
        _mint(_genesisPool, INITIAL_GENESIS_POOL_DISTRIBUTION);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
