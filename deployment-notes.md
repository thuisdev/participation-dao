# Sepolia Deployment

## Contracts
- ParticipationToken: 0x548Fe7749Ca154cA1Da13c60e53804EEdBC248f4
- TimelockController: 0x2cC3379Ff762bf3637c39882E8e6220D9eC05ba3
- ParticipationGovernor: 0x3dfB8983Bcb56aaFCac5106f7FdF92A94E2DFC75
- Treasury: 0xB9f71cd56d155198eED394C993f68fF17BBA9F6c
- Earner: 0xAae4403926340F6e9c35D7B96E87FFb2520FC083

## Demo proposal
- Description: Proposal #1: accept token admin and grant 0.05 ETH to grantee
- Proposal ID: 103374908272685966258408061505453427036443460302698054147742314075185104446970
- Grantee: 0xaA49F30a1F0b51Aa7E2b03399Aa623F7D8ed2De8
- Execution tx: 0x4b1b7ec5c5c072aeee95ebc99c0a0714ce26cbe331c47feaf7d40082b0b3e25b

## Before
- Treasury: 0.1 ETH
- Grantee: 0.382117093845612718 ETH
- Token admin: deployer (transfer to timelock pending)

## After
- Proposal state: 7 (Executed)
- Treasury: 0.05 ETH
- Grantee: 0.432117093845612718 ETH
- Token admin: 0x2cC3379Ff762bf3637c39882E8e6220D9eC05ba3
