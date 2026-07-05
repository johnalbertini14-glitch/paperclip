"""
Outlook subscription renewal cron job.

Renews Microsoft Graph subscriptions before they expire.
"""

import asyncio
import logging
from datetime import datetime, timedelta

from backend.core.database import SessionLocal
from backend.core.models import Integration, Subscription
from backend.core.services.outlook_service import OutlookService

logger = logging.getLogger(__name__)


async def renew_outlook_subscriptions():
    """
    Renew Outlook subscriptions that are expiring soon.
    
    Runs as a cron job to check and renew subscriptions
    that expire within the next 24 hours.
    """
    logger.info("Starting Outlook subscription renewal job")
    
    try:
        with SessionLocal() as db:
            # Find subscriptions expiring in the next 24 hours
            expiration_threshold = datetime.utcnow() + timedelta(hours=24)
            
            subscriptions = db.query(Subscription).filter(
                Subscription.provider == "outlook",
                Subscription.expires_at <= expiration_threshold,
                Subscription.active == True
            ).all()
            
            if not subscriptions:
                logger.info("No Outlook subscriptions need renewal")
                return
            
            logger.info(f"Found {len(subscriptions)} Outlook subscriptions to renew")
            
            outlook_service = OutlookService()
            renewed_count = 0
            failed_count = 0
            
            for subscription in subscriptions:
                try:
                    # Get associated integration
                    integration = db.query(Integration).filter(
                        Integration.id == subscription.integration_id
                    ).first()
                    
                    if not integration:
                        logger.warning(
                            f"Integration {subscription.integration_id} not found "
                            f"for subscription {subscription.id}"
                        )
                        subscription.active = False
                        db.commit()
                        failed_count += 1
                        continue
                    
                    # Renew subscription
                    success = await outlook_service.renew_subscription(
                        integration,
                        subscription
                    )
                    
                    if success:
                        renewed_count += 1
                        logger.info(
                            f"Renewed subscription {subscription.id} "
                            f"for integration {integration.id}"
                        )
                    else:
                        failed_count += 1
                        logger.error(
                            f"Failed to renew subscription {subscription.id} "
                            f"for integration {integration.id}"
                        )
                        
                except Exception as e:
                    logger.error(
                        f"Error renewing subscription {subscription.id}: {e}",
                        exc_info=True
                    )
                    failed_count += 1
            
            logger.info(
                f"Outlook subscription renewal completed: "
                f"{renewed_count} renewed, {failed_count} failed"
            )
            
    except Exception as e:
        logger.error(f"Error in Outlook subscription renewal job: {e}", exc_info=True)


async def cleanup_expired_subscriptions():
    """
    Clean up expired Outlook subscriptions.
    
    Marks subscriptions as inactive after they expire.
    """
    logger.info("Starting expired Outlook subscription cleanup")
    
    try:
        with SessionLocal() as db:
            # Find subscriptions that have expired
            expired_subscriptions = db.query(Subscription).filter(
                Subscription.provider == "outlook",
                Subscription.expires_at <= datetime.utcnow(),
                Subscription.active == True
            ).all()
            
            if not expired_subscriptions:
                logger.info("No expired Outlook subscriptions to clean up")
                return
            
            logger.info(f"Found {len(expired_subscriptions)} expired Outlook subscriptions")
            
            for subscription in expired_subscriptions:
                subscription.active = False
                subscription.updated_at = datetime.utcnow()
                logger.info(f"Marked subscription {subscription.id} as inactive")
            
            db.commit()
            logger.info(f"Cleaned up {len(expired_subscriptions)} expired subscriptions")
            
    except Exception as e:
        logger.error(f"Error cleaning up expired subscriptions: {e}", exc_info=True)


async def main():
    """Main entry point for cron job."""
    try:
        # Run renewal job
        await renew_outlook_subscriptions()
        
        # Run cleanup job
        await cleanup_expired_subscriptions()
        
    except Exception as e:
        logger.error(f"Error in Outlook cron job: {e}", exc_info=True)


if __name__ == "__main__":
    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )
    
    # Run the cron job
    asyncio.run(main())