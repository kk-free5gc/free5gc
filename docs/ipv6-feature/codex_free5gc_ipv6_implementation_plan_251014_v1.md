# IPv6 Address Allocation Enhancement Plan for free5gc + gtp5g

In this working directory, there are two core network projects:

1. **open5gs**  
2. **free5gc + gtp5g (UPF)**

I already know that **open5gs** supports allocating IPv6 addresses to clients, but **free5gc + gtp5g** does not.  

Here is the codebase analysis describing how open5gs allocates IPv6 addresses to clients:  
`./open5gs/docs/codex_IPv6_UE_Addressing_Findings.md`

Now I would like you to help me **generate a Markdown implementation plan** that applies the **open5gs IPv6 allocation method** to enable **free5gc + gtp5g** to allocate IPv6 addresses to clients.

Now I would like you to help me **generate a Markdown implementation plan** to enable **free5gc + gtp5g** to allocate IPv6 addresses to clients using the similar approach as **open5gs**.

---

## Notes

1. Please break down the implementation plan into several **phases**, so we can implement it step by step.  
2. Show me your **implementation structure** first.  
3. open5gs allocates IPv4/IPv6 address pools **without considering NSSAI settings**.  
   Currently, free5gc + gtp5g allocates **IPv4 address pools per NSSAI setting**.  
   I want to **retain this behavior** when enabling IPv6 address allocation.  
4. General guidelines:  
   - If similar IPv4 function exist, please follow with the similar existing approach to implement IPv6 function to keep the logic consistent.  
   - Maintain naming consistency (Avoid introducing new variable types unless necessary. Reference IPv4 naming to create IPv6 naming.).  
   - Use clear and understandable names (Avoid confusing/too brief naming conventions).  
   - Ensure sufficient debug logging.  
     Add the prefix **"WNC"** to all new log messages, making it easier to identify if an error originates from our custom code.  
5. Since **free5gc + gtp5g** includes multiple submodules, please clearly define the **responsibility of each stage’s implementation**.
